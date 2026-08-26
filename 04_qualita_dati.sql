-- =============================================================================
--  Controlli di qualita' dei dati.
--
--  Ogni query qui sotto dovrebbe restituire ZERO righe. Se ne restituisce, il
--  dato e' rotto e le analisi in 03_analisi.sql sono sbagliate senza dirlo.
--
--  ESITO DELL'ULTIMA ESECUZIONE. Attenzione a SU COSA: i dump
--  `serie_a_25_26_*.sql` del motore, che sono una fotografia del 16 marzo 2026
--  (280 partite, 8.772 righe giocatore-partita) e NON il database corrente -
--  non hanno nemmeno la colonna `season`. Sei controlli passano, quattro no,
--  e i quattro vanno letti sapendo su cosa hanno girato.
--
--    1  partite senza due squadre .................. 0 righe   OK
--    2  lati non complementari ..................... 0 righe   OK
--    3  goal incoerenti ............................ 0 righe   OK
--    4  giocatore in partita non della sua squadra 184 righe   limite noto del modello
--    5  valori impossibili ......................... 0 righe   OK
--    6  giocatori senza ruolo ..................... 48 righe   da riverificare sul vivo
--    6b omonimi nella stessa squadra .............. 0 righe   OK
--    7  giornate non da dieci partite ............. 21 righe   gia' risolto a monte
--    7b squadra due volte nella stessa giornata .. 164 righe   stesso, gia' risolto
--    8  partite senza righe giocatore .............. 0 righe   OK
--
--  I numeri stanno qui perche' questi controlli sono stati eseguiti davvero,
--  e non solo scritti.
--
--  Non sono controlli teorici: sono i modi in cui questo database si e' rotto
--  davvero durante l'importazione da due fonti esterne. Righe orfane, omonimi e
--  record doppi hanno tutti richiesto uno script di riparazione dedicato.
--
--  Il principio: quello che il database puo' impedire, lo impedisce da solo con
--  un vincolo (vedi `uq_gp` e la chiave composta in 01_schema.sql). Quello che
--  non e' esprimibile come vincolo diventa un controllo qui, da lanciare dopo
--  ogni caricamento. Un controllo che nessuno esegue non e' un controllo.
-- =============================================================================

SET NAMES utf8mb4;


-- -----------------------------------------------------------------------------
--  1. Ogni partita deve avere esattamente due righe in squadra_calendario.
--     Una sola = importazione interrotta a meta'. Tre = doppione.
-- -----------------------------------------------------------------------------
SELECT 'partite senza due squadre' AS controllo,
       c.id AS calendario_id, c.giornata, COUNT(sk.squadra_id) AS righe_trovate
FROM calendario c
LEFT JOIN squadra_calendario sk ON sk.calendario_id = c.id
GROUP BY c.id, c.giornata
HAVING righe_trovate <> 2;


-- -----------------------------------------------------------------------------
--  2. Le due righe di una partita devono essere una 'casa' e una 'trasferta'.
--     Due 'casa' significa che il lato e' stato assegnato male: le classifiche
--     casa/trasferta diventerebbero sbagliate senza che nulla lo segnali.
-- -----------------------------------------------------------------------------
SELECT 'lati non complementari' AS controllo,
       calendario_id,
       SUM(ruolo = 'casa')      AS righe_casa,
       SUM(ruolo = 'trasferta') AS righe_trasferta
FROM squadra_calendario
GROUP BY calendario_id
HAVING righe_casa <> 1 OR righe_trasferta <> 1;


-- -----------------------------------------------------------------------------
--  3. I goal della squadra devono coincidere con quelli in calendario.
--     Sono due registrazioni dello stesso fatto, arrivate per strade diverse:
--     se divergono, una delle due importazioni e' andata storta.
-- -----------------------------------------------------------------------------
SELECT 'goal incoerenti fra calendario e squadra' AS controllo,
       c.id AS calendario_id, c.giornata,
       c.goal_casa, c.goal_trasferta,
       MAX(CASE WHEN sk.ruolo = 'casa'      THEN sk.goal_fatti END) AS gf_casa,
       MAX(CASE WHEN sk.ruolo = 'trasferta' THEN sk.goal_fatti END) AS gf_trasferta
FROM calendario c
JOIN squadra_calendario sk ON sk.calendario_id = c.id
GROUP BY c.id, c.giornata, c.goal_casa, c.goal_trasferta
HAVING gf_casa <> c.goal_casa OR gf_trasferta <> c.goal_trasferta;


-- -----------------------------------------------------------------------------
--  4. Un giocatore non puo' comparire in una partita che la sua squadra non ha
--     giocato. E' il controllo che intercetta l'aggancio sbagliato fra le fonti:
--     un omonimo attribuito alla squadra sbagliata finisce esattamente qui.
--
--     Limite noto: il database non ha lo storico dei trasferimenti, quindi un
--     giocatore ceduto a gennaio risulta legato alla squadra di arrivo anche per
--     le partite giocate con quella di partenza. Questa query li segnalerebbe
--     come errori. E' un limite del modello, non un difetto del controllo, e va
--     letto sapendolo.
-- -----------------------------------------------------------------------------
SELECT 'giocatore in una partita non della sua squadra' AS controllo,
       CONCAT(g.nome, ' ', g.cognome) AS giocatore,
       sq.nome AS squadra_anagrafica,
       c.giornata, c.id AS calendario_id
FROM giocatore_partita gp
JOIN giocatori g  ON g.id  = gp.giocatore_id
JOIN squadre sq   ON sq.id = g.squadra_id
JOIN calendario c ON c.id  = gp.calendario_id
WHERE g.squadra_id NOT IN (c.squadra_casa_id, c.squadra_trasferta_id);


-- -----------------------------------------------------------------------------
--  5. Valori fuori dal possibile.
--     Il tempo regolamentare piu' i recuperi non arriva a 120 minuti in una
--     partita di campionato; gli xG sono probabilita' sommate e non scendono
--     sotto zero; nessuno prende due rossi.
-- -----------------------------------------------------------------------------
SELECT 'valori impossibili' AS controllo,
       gp.id, CONCAT(g.nome, ' ', g.cognome) AS giocatore,
       gp.minuti, gp.goal, gp.tiri, gp.xg, gp.rossi
FROM giocatore_partita gp
JOIN giocatori g ON g.id = gp.giocatore_id
WHERE gp.minuti < 0 OR gp.minuti > 120
   OR gp.goal   < 0 OR gp.assist > 5
   OR gp.xg     < 0 OR gp.xa     < 0
   OR gp.rossi NOT IN (0, 1)
   OR gp.goal > gp.tiri;          -- non si segna senza tirare (autogol esclusi:
                                  -- l'autogol e' attribuito all'altra squadra)


-- -----------------------------------------------------------------------------
--  6. Anagrafiche incomplete o duplicate.
--     Il ruolo mancante esclude silenziosamente il giocatore da ogni analisi che
--     filtra per ruolo: sparisce dai risultati senza comparire in nessun errore.
-- -----------------------------------------------------------------------------
SELECT 'giocatori senza ruolo' AS controllo,
       g.id, CONCAT(g.nome, ' ', g.cognome) AS giocatore, sq.nome AS squadra
FROM giocatori g
JOIN squadre sq ON sq.id = g.squadra_id
WHERE g.ruolo IS NULL;

SELECT 'possibili omonimi nella stessa squadra' AS controllo,
       sq.nome AS squadra, g.nome, g.cognome, COUNT(*) AS occorrenze
FROM giocatori g
JOIN squadre sq ON sq.id = g.squadra_id
GROUP BY sq.nome, g.nome, g.cognome
HAVING occorrenze > 1;


-- -----------------------------------------------------------------------------
--  7. Copertura del campionato.
--     A venti squadre ogni giornata ha dieci partite e ogni squadra ne gioca una
--     sola. Se salta, e' stata importata una partita di un'altra competizione o
--     una giornata e' incompleta.
-- -----------------------------------------------------------------------------
SELECT 'giornate non da dieci partite' AS controllo,
       giornata, COUNT(*) AS partite
FROM calendario
GROUP BY giornata
HAVING partite <> 10;

SELECT 'squadra impegnata due volte nella stessa giornata' AS controllo,
       s.nome AS squadra, c.giornata, COUNT(*) AS partite
FROM squadra_calendario sk
JOIN calendario c ON c.id = sk.calendario_id
JOIN squadre s    ON s.id = sk.squadra_id
GROUP BY s.id, s.nome, c.giornata
HAVING partite > 1;


-- -----------------------------------------------------------------------------
--  8. Partite senza nessun giocatore.
--     La partita esiste nel calendario ma il dettaglio giocatore-partita non e'
--     mai arrivato. Non rompe le classifiche di squadra - e' questo che la rende
--     insidiosa: tutto sembra a posto finche' non si guardano i marcatori.
-- -----------------------------------------------------------------------------
SELECT 'partite senza righe giocatore' AS controllo,
       c.id AS calendario_id, c.giornata, c.data
FROM calendario c
LEFT JOIN giocatore_partita gp ON gp.calendario_id = c.id
WHERE gp.id IS NULL;


-- =============================================================================
--  Cosa significano i quattro controlli che restituiscono righe
--
--  4 - 184 righe. Sono trasferimenti. L'anagrafica tiene UNA squadra per
--      giocatore, quella attuale, mentre le partite restano attribuite a chi le
--      ha giocate: chi si e' mosso a gennaio risulta in partite della squadra
--      che ha lasciato. Non e' un errore di importazione, e' il modello che non
--      ha lo storico dei trasferimenti. Va saputo prima di aggregare per
--      squadra: i totali di squadra includono minuti giocati altrove.
--
--  6 - 48 giocatori senza ruolo, sulla fotografia di marzo; lo stato attuale
--      non e' stato verificato. Questi spariscono in silenzio da ogni query che
--      filtra per ruolo (la 5 in 03_analisi.sql lo fa): non danno errore, non
--      compaiono nei risultati, e nessuno se ne accorge. E' il tipo di difetto
--      peggiore, perche' non si manifesta.
--
--  7 e 7b - GIA' RISOLTO A MONTE, e la riga qui sotto vale solo per la
--      fotografia di marzo. In quel dump `giornata` non e' la giornata di
--      campionato: 21 valori distinti per 280 partite, 16 partite nella
--      "giornata 1", squadre che compaiono due volte nello stesso valore a una
--      settimana di distanza. Understat espone le date, non il numero di
--      giornata. Il motore lo ha poi risolto derivando la giornata
--      dall'invariante "una squadra gioca una sola partita per giornata", in
--      modo robusto a rinvii e recuperi, e usandola solo come filtro di
--      presentazione, mai nel calcolo dell'indice.
--      Resta comunque la regola pratica: **ordinare per `data`**, che non
--      dipende da nessuna derivazione. La query 2 di 03_analisi.sql fa cosi'.
--
-- =============================================================================
--  Un controllo che di proposito NON c'e':
--
--  "la somma dei goal dei giocatori deve fare i goal della squadra".
--  Non torna quasi mai, e non e' un errore: gli autogol vengono conteggiati alla
--  squadra ma non a un attaccante avversario. Metterlo qui produrrebbe righe a
--  ogni esecuzione, e un controllo che segnala sempre viene ignorato sempre -
--  poi trascina con se' anche gli otto che funzionano.
-- =============================================================================
