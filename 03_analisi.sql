-- =============================================================================
--  Sei domande che le viste non sanno rispondere.
--
--  Le nove viste in 02_viste.sql descrivono: chi ha segnato, come e' finita, chi
--  sta davanti. Sono utili e le scriverebbe chiunque. Queste sei invece provano
--  a rispondere a domande su cui qualcuno deve poi decidere qualcosa.
--
--  Sotto ognuna c'e' una riga "NON dice": e' la parte che di solito manca, ed e'
--  quella che separa un numero da una risposta. Un numero senza il suo limite
--  scritto accanto verra' usato per rispondere alla domanda sbagliata.
--
--  MySQL 8.0 (servono le funzioni finestra e le CTE).
-- =============================================================================

SET NAMES utf8mb4;


-- -----------------------------------------------------------------------------
--  1. Chi sta segnando piu' di quanto dovrebbe, e quindi calera'?
--
--  xG e' quanti goal ci si aspettava dai tiri tentati. La differenza fra goal
--  fatti e xG e' finalizzazione piu' fortuna, e la fortuna non si ripete.
--  Serve a due decisioni opposte: non comprare chi e' in cima a questa lista al
--  prezzo di adesso, e non svendere chi e' in fondo.
--
--  La soglia sui minuti non e' cosmetica: su 200 minuti un +2.5 e' rumore.
-- -----------------------------------------------------------------------------
SELECT
    CONCAT(g.nome, ' ', g.cognome)                             AS giocatore,
    sq.nome                                                    AS squadra,
    g.ruolo                                                    AS ruolo,
    SUM(gp.minuti)                                             AS minuti,
    SUM(gp.goal)                                               AS goal,
    ROUND(SUM(gp.xg), 2)                                       AS xg,
    ROUND(SUM(gp.goal) - SUM(gp.xg), 2)                        AS scarto,
    -- lo scarto per 90 minuti: rende confrontabili titolari e subentranti
    ROUND((SUM(gp.goal) - SUM(gp.xg)) * 90.0
          / NULLIF(SUM(gp.minuti), 0), 3)                      AS scarto_per_90
FROM giocatori g
JOIN squadre sq           ON sq.id = g.squadra_id
JOIN giocatore_partita gp ON gp.giocatore_id = g.id
GROUP BY g.id, g.nome, g.cognome, sq.nome, g.ruolo
-- L'aggregato e' ripetuto per esteso invece di riusare l'alias `minuti`:
--   l'alias ha lo stesso nome della colonna `gp.minuti`, e quale dei due vince
--   in HAVING dipende dal motore. MySQL preferisce l'alias, SQLite la colonna,
--   e la stessa query restituisce due risultati diversi. Verificato, non teorico.
HAVING SUM(gp.minuti) >= 450   -- cinque partite intere: sotto, il dato non regge
   AND SUM(gp.xg) > 0          -- chi non tira non e' un finalizzatore fortunato
ORDER BY scarto DESC
LIMIT 20;

-- NON dice: chi ha finalizzato bene. Uno scarto positivo puo' venire da un
-- talento reale nel tiro o da un semestre fortunato, e questa query non le
-- distingue. Per farlo servono piu' stagioni dello stesso giocatore.


-- -----------------------------------------------------------------------------
--  2. Chi sta arrivando in forma, e chi sta scivolando?
--
--  La classifica somma tutta la stagione e quindi non vede il presente: una
--  squadra puo' essere sesta e avere perso le ultime cinque. Qui la media punti
--  su una finestra mobile di cinque partite, per ogni partita giocata.
--
--  Serve per la domanda su cui si scommette davvero: come arriva alla prossima.
--
--  ATTENZIONE alla colonna d'ordinamento: la finestra e' ordinata per `c.data`
--  e NON per `c.giornata`. La colonna `giornata` in questo database non e' la
--  giornata di campionato ed e' inaffidabile (vedi il controllo 7 in
--  04_qualita_dati.sql e la sezione "Dati sporchi" nel README): ordinare per
--  giornata metterebbe le partite nella sequenza sbagliata, e una media mobile
--  su una sequenza sbagliata e' un numero peggiore di nessun numero.
-- -----------------------------------------------------------------------------
SELECT
    s.nome                                                     AS squadra,
    c.data                                                     AS data,
    sk.punti                                                   AS punti,
    ROUND(AVG(sk.punti) OVER (
              PARTITION BY s.id
              ORDER BY c.data
              ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
          ), 2)                                                AS media_ultime_5,
    ROUND(AVG(sk.xg) OVER (
              PARTITION BY s.id
              ORDER BY c.data
              ROWS BETWEEN 4 PRECEDING AND CURRENT ROW
          ), 2)                                                AS xg_medio_ultime_5
FROM squadra_calendario sk
JOIN squadre s    ON s.id = sk.squadra_id
JOIN calendario c ON c.id = sk.calendario_id
ORDER BY s.nome, c.data;

-- NON dice: se il calo e' la squadra o il calendario. Cinque partite contro le
-- prime sei producono la stessa curva di cinque brutte prestazioni. Per
-- separarle serve pesare l'avversario (vedi la query 6).


-- -----------------------------------------------------------------------------
--  3. Quali squadre stanno sopra o sotto quello che il gioco dice?
--
--  Due classifiche: quella dei punti e quella degli xG prodotti. Il confronto
--  fra le due posizioni e' il segnale piu' onesto su chi sta correndo con il
--  vento a favore.
--
--  Un divario grande e positivo (posizione reale molto migliore di quella xG)
--  storicamente rientra. E' l'indicatore su cui un direttore sportivo decide se
--  la squadra va rinforzata o se sta solo avendo una buona annata.
-- -----------------------------------------------------------------------------
WITH per_squadra AS (
    SELECT
        s.id                                                   AS squadra_id,
        s.nome                                                 AS squadra,
        SUM(sk.punti)                                          AS punti,
        SUM(sk.xg)                                             AS xg_prodotti,
        SUM(sk.xg_subiti)                                      AS xg_concessi
    FROM squadre s
    JOIN squadra_calendario sk ON sk.squadra_id = s.id
    GROUP BY s.id, s.nome
),
posizioni AS (
    SELECT
        squadra,
        punti,
        ROUND(xg_prodotti, 1)                                  AS xg_prodotti,
        ROUND(xg_prodotti - xg_concessi, 1)                    AS xg_netti,
        RANK() OVER (ORDER BY punti DESC)                      AS pos_reale,
        RANK() OVER (ORDER BY (xg_prodotti - xg_concessi) DESC) AS pos_attesa
    FROM per_squadra
)
SELECT
    squadra,
    punti,
    xg_netti,
    pos_reale,
    pos_attesa,
    pos_attesa - pos_reale                                     AS scarto_posizioni,
    CASE
        WHEN pos_attesa - pos_reale >=  3 THEN 'sta correndo sopra il proprio gioco'
        WHEN pos_attesa - pos_reale <= -3 THEN 'sta raccogliendo meno di quanto crea'
        ELSE 'in linea'
    END                                                        AS lettura
FROM posizioni
ORDER BY scarto_posizioni DESC;

-- NON dice: che la posizione attesa sia quella "giusta". Gli xG misurano la
-- qualita' dei tiri, non la capacita' di difendere un vantaggio, di segnare su
-- palla inattiva o di avere un portiere migliore degli altri. Alcune squadre
-- stanno sopra i propri xG ogni anno, e non e' fortuna.


-- -----------------------------------------------------------------------------
--  4. Quanto dipende una squadra da un solo giocatore?
--
--  La quota di xG di squadra prodotta dal suo miglior produttore. Sopra una
--  certa soglia non e' un punto di forza, e' un rischio: un infortunio e
--  l'attacco si spegne.
--
--  Il pezzo di SQL che conta e' la funzione finestra SUM() OVER (PARTITION BY
--  squadra) accanto a un GROUP BY per giocatore: mette sulla stessa riga il
--  totale del giocatore e il totale della sua squadra, che altrimenti sono due
--  livelli di aggregazione diversi e richiederebbero una subquery correlata.
-- -----------------------------------------------------------------------------
WITH per_giocatore AS (
    SELECT
        sq.id                                                  AS squadra_id,
        sq.nome                                                AS squadra,
        CONCAT(g.nome, ' ', g.cognome)                         AS giocatore,
        SUM(gp.xg + gp.xa)                                     AS pericolo_prodotto
    FROM giocatori g
    JOIN squadre sq           ON sq.id = g.squadra_id
    JOIN giocatore_partita gp ON gp.giocatore_id = g.id
    GROUP BY sq.id, sq.nome, g.id, g.nome, g.cognome
),
con_totali AS (
    SELECT
        squadra,
        giocatore,
        pericolo_prodotto,
        SUM(pericolo_prodotto) OVER (PARTITION BY squadra_id)  AS totale_squadra,
        ROW_NUMBER()           OVER (PARTITION BY squadra_id
                                     ORDER BY pericolo_prodotto DESC) AS posizione
    FROM per_giocatore
)
SELECT
    squadra,
    giocatore                                                  AS primo_produttore,
    ROUND(pericolo_prodotto, 2)                                AS xg_piu_xa,
    ROUND(totale_squadra, 2)                                   AS totale_squadra,
    ROUND(100.0 * pericolo_prodotto / NULLIF(totale_squadra, 0), 1) AS quota_pct
FROM con_totali
WHERE posizione = 1
ORDER BY quota_pct DESC;

-- NON dice: che la dipendenza sia un difetto. Una squadra costruita attorno a un
-- fuoriclasse ha una quota alta per scelta, non per poverta' di alternative. Il
-- numero segnala dove guardare, non cosa concludere.


-- -----------------------------------------------------------------------------
--  5. Chi rende di piu' quando gioca, al netto di quanto gioca?
--
--  I totali premiano chi e' sempre in campo. Normalizzando per 90 minuti si
--  vedono le riserve che producono quanto i titolari - che e' esattamente la
--  domanda di chi cerca un rinforzo che costi poco.
--
--  La soglia HAVING e' l'unica difesa contro il caso limite: un goal in dieci
--  minuti fa 9.0 per 90, ed e' un numero senza significato.
-- -----------------------------------------------------------------------------
SELECT
    CONCAT(g.nome, ' ', g.cognome)                             AS giocatore,
    sq.nome                                                    AS squadra,
    g.ruolo                                                    AS ruolo,
    COUNT(gp.id)                                               AS presenze,
    SUM(gp.minuti)                                             AS minuti,
    ROUND(SUM(gp.minuti) / NULLIF(COUNT(gp.id), 0), 0)         AS minuti_medi,
    SUM(gp.goal) + SUM(gp.assist)                              AS contributi,
    ROUND((SUM(gp.goal) + SUM(gp.assist)) * 90.0
          / NULLIF(SUM(gp.minuti), 0), 2)                      AS contributi_per_90,
    ROUND((SUM(gp.xg) + SUM(gp.xa)) * 90.0
          / NULLIF(SUM(gp.minuti), 0), 2)                      AS attesi_per_90
FROM giocatori g
JOIN squadre sq           ON sq.id = g.squadra_id
JOIN giocatore_partita gp ON gp.giocatore_id = g.id
WHERE g.ruolo IN ('CEN','ATT')     -- il criterio e' offensivo: sui difensori direbbe altro
GROUP BY g.id, g.nome, g.cognome, sq.nome, g.ruolo
HAVING SUM(gp.minuti) >= 450   -- stesso motivo della query 1: aggregato esplicito
ORDER BY contributi_per_90 DESC
LIMIT 25;

-- NON dice: che chi e' in cima renderebbe uguale da titolare. Entrare al 70' con
-- la partita aperta e giocarla dal primo minuto sono due lavori diversi, e i
-- minuti da subentrante sono sistematicamente piu' produttivi.


-- -----------------------------------------------------------------------------
--  6. Contro chi ha giocato, davvero, ogni squadra?
--
--  La difficolta' del calendario affrontato finora: la media dei punti per
--  partita degli avversari incontrati. Serve a leggere tutte le query
--  precedenti: una media punti bassa contro un calendario duro non e' un calo.
--
--  Il pezzo interessante e' che "gli avversari di una squadra" non e' una
--  relazione che esiste nel database. Va costruita facendo incontrare
--  `squadra_calendario` con se' stessa sulla stessa partita, tenendo le righe in
--  cui la squadra e' diversa: un self join, che qui e' l'unico modo di
--  esprimere "l'altro".
-- -----------------------------------------------------------------------------
WITH forza_squadra AS (
    -- quanto vale ciascuna squadra, in punti per partita sull'intera stagione
    SELECT
        squadra_id,
        SUM(punti) / NULLIF(COUNT(*), 0)                       AS ppg
    FROM squadra_calendario
    GROUP BY squadra_id
)
SELECT
    s.nome                                                     AS squadra,
    COUNT(*)                                                   AS partite,
    ROUND(AVG(f.ppg), 3)                                       AS forza_media_avversari,
    ROUND(SUM(mia.punti) / NULLIF(COUNT(*), 0), 3)             AS punti_per_partita,
    -- il rapporto fra quanto ha raccolto e quanto valevano gli avversari
    ROUND((SUM(mia.punti) / NULLIF(COUNT(*), 0)) - AVG(f.ppg), 3) AS margine
FROM squadra_calendario mia
JOIN squadra_calendario avv
     ON  avv.calendario_id = mia.calendario_id    -- stessa partita
     AND avv.squadra_id   <> mia.squadra_id       -- l'altra squadra
JOIN squadre s        ON s.id = mia.squadra_id
JOIN forza_squadra f  ON f.squadra_id = avv.squadra_id
GROUP BY s.id, s.nome
ORDER BY forza_media_avversari DESC;

-- NON dice: quanto sara' duro il calendario che resta. E c'e' una circolarita'
-- da tenere presente: la forza degli avversari e' calcolata sui punti di tutta
-- la stagione, che includono le partite giocate contro di te. A venti squadre
-- l'effetto e' piccolo, ma non e' zero, e va detto invece che nascosto.
