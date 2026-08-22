-- =============================================================================
--  Le nove viste, una per una.
--
--  Sopra ogni vista c'e' la domanda a cui risponde. Se una vista non risponde a
--  una domanda che qualcuno fa davvero, non e' una vista: e' una query salvata
--  nel posto sbagliato.
--
--  Sono riscritte leggibili rispetto a come MySQL le restituisce da
--  SHOW CREATE VIEW (che rimuove gli a capo e mette i backtick ovunque).
--  La logica e' identica.
-- =============================================================================

SET NAMES utf8mb4;


-- -----------------------------------------------------------------------------
--  v_classifica
--  "Come sta andando il campionato?"
--
--  La classifica vera. Il punto interessante e' l'aggregazione condizionale:
--  in MySQL `sk.risultato = 'vittoria'` vale 1 o 0, quindi SUM() sopra una
--  condizione conta le occorrenze senza bisogno di tre query separate o di tre
--  CASE WHEN. Un pivot fatto con l'aritmetica.
--
--  L'ordinamento a criteri multipli (punti, poi differenza reti, poi goal
--  fatti) e' il regolamento della Serie A, non una preferenza.
--
--  xG e' sommato accanto ai punti di proposito: mette una accanto all'altra la
--  classifica che conta e quella che il gioco suggerirebbe.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_classifica AS
SELECT
    s.nome                                              AS squadra,
    COUNT(0)                                            AS G,
    SUM(sk.risultato = 'vittoria')                      AS V,
    SUM(sk.risultato = 'pareggio')                      AS P,
    SUM(sk.risultato = 'sconfitta')                     AS S,
    SUM(sk.goal_fatti)                                  AS GF,
    SUM(sk.goal_subiti)                                 AS GS,
    SUM(sk.goal_fatti) - SUM(sk.goal_subiti)            AS DR,
    SUM(sk.punti)                                       AS Pt,
    SUM(sk.xg)                                          AS xG
FROM squadre s
JOIN squadra_calendario sk ON sk.squadra_id = s.id
GROUP BY s.id, s.nome
ORDER BY Pt DESC, DR DESC, GF DESC;


-- -----------------------------------------------------------------------------
--  v_classifica_casa
--  "Quali squadre vivono del fattore campo?"
--
--  Stessa classifica, ma il filtro sta nella condizione di JOIN e non in una
--  WHERE. Su un INNER JOIN le due forme danno lo stesso risultato; qui e' scritto
--  cosi' perche' il filtro appartiene alla relazione (quali partite della squadra
--  guardo) e non al risultato (quali righe tengo).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_classifica_casa AS
SELECT
    s.nome                                              AS squadra,
    COUNT(0)                                            AS G,
    SUM(sk.risultato = 'vittoria')                      AS V,
    SUM(sk.risultato = 'pareggio')                      AS P,
    SUM(sk.risultato = 'sconfitta')                     AS S,
    SUM(sk.goal_fatti)                                  AS GF,
    SUM(sk.goal_subiti)                                 AS GS,
    SUM(sk.punti)                                       AS Pt,
    SUM(sk.xg)                                          AS xG
FROM squadre s
JOIN squadra_calendario sk
     ON sk.squadra_id = s.id
    AND sk.ruolo = 'casa'
GROUP BY s.id, s.nome
ORDER BY Pt DESC, GF DESC;


-- -----------------------------------------------------------------------------
--  v_classifica_trasferta
--  "E fuori casa, chi regge?"
--
--  Il gemello della precedente. Le due lette insieme rispondono a una domanda
--  che la classifica generale nasconde: una squadra da 40 punti fatti tutti in
--  casa e una da 40 punti divisi a meta' non sono la stessa squadra.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_classifica_trasferta AS
SELECT
    s.nome                                              AS squadra,
    COUNT(0)                                            AS G,
    SUM(sk.risultato = 'vittoria')                      AS V,
    SUM(sk.risultato = 'pareggio')                      AS P,
    SUM(sk.risultato = 'sconfitta')                     AS S,
    SUM(sk.goal_fatti)                                  AS GF,
    SUM(sk.goal_subiti)                                 AS GS,
    SUM(sk.punti)                                       AS Pt,
    SUM(sk.xg)                                          AS xG
FROM squadre s
JOIN squadra_calendario sk
     ON sk.squadra_id = s.id
    AND sk.ruolo = 'trasferta'
GROUP BY s.id, s.nome
ORDER BY Pt DESC, GF DESC;


-- -----------------------------------------------------------------------------
--  v_marcatori
--  "Chi sta segnando, e quanto gli costa farlo?"
--
--  Oltre ai goal, due cose:
--
--  - `contributi` = goal + assist, perche' per un attaccante esterno o un
--    trequartista i soli goal sottostimano il contributo offensivo;
--  - `min_per_goal` con NULLIF(sum(goal), 0): senza, chi non ha segnato dividerebbe
--    per zero. NULLIF trasforma lo zero in NULL e la divisione restituisce NULL,
--    cioe' "non calcolabile" invece di un errore o di un numero inventato.
--    E' la differenza fra un dato mancante e un dato sbagliato.
--
--  xG e xA accanto a goal e assist servono a leggere la sostenibilita': chi ha
--  8 goal su 3.0 di xG sta finendo sopra le sue possibilita', e prima o poi
--  rientra. Vedi anche la query 1 in 03_analisi.sql.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_marcatori AS
SELECT
    CONCAT(g.nome, ' ', g.cognome)                      AS nome,
    sq.nome                                             AS squadra,
    COUNT(gp.id)                                        AS partite,
    SUM(gp.minuti)                                      AS minuti,
    SUM(gp.goal)                                        AS goal,
    SUM(gp.assist)                                      AS assist,
    SUM(gp.goal) + SUM(gp.assist)                       AS contributi,
    SUM(gp.xg)                                          AS xG,
    SUM(gp.xa)                                          AS xA,
    SUM(gp.tiri)                                        AS tiri,
    ROUND(SUM(gp.minuti) / NULLIF(SUM(gp.goal), 0), 0)  AS min_per_goal
FROM giocatori g
JOIN squadre sq          ON sq.id = g.squadra_id
JOIN giocatore_partita gp ON gp.giocatore_id = g.id
GROUP BY g.id, g.nome, g.cognome, sq.nome
ORDER BY goal DESC;


-- -----------------------------------------------------------------------------
--  v_assistman
--  "Chi crea le occasioni per gli altri?"
--
--  Deliberatamente piu' povera di v_marcatori: gli assist accanto agli xA, e
--  basta. xA e' la misura piu' onesta della creazione, perche' non dipende da
--  quanto e' bravo a segnare il compagno che riceve il passaggio.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_assistman AS
SELECT
    CONCAT(g.nome, ' ', g.cognome)                      AS nome,
    sq.nome                                             AS squadra,
    COUNT(gp.id)                                        AS partite,
    SUM(gp.assist)                                      AS assist,
    SUM(gp.goal)                                        AS goal,
    SUM(gp.xa)                                          AS xA
FROM giocatori g
JOIN squadre sq          ON sq.id = g.squadra_id
JOIN giocatore_partita gp ON gp.giocatore_id = g.id
GROUP BY g.id, g.nome, g.cognome, sq.nome
ORDER BY assist DESC;


-- -----------------------------------------------------------------------------
--  v_xg_giocatori
--  "Quanto pericolo produce un giocatore, e con che continuita'?"
--
--  Il totale e la media stanno una accanto all'altra apposta: `xg_totale` premia
--  chi gioca tanto, `xg_media` (per partita) premia chi rende quando c'e'.
--  Guardarne uno solo dei due porta a due classifiche diverse ed entrambe zoppe.
--
--  Attenzione al GROUP BY: include `gp.ruolo` (casa/trasferta), quindi un
--  giocatore compare in DUE righe, una per contesto. Non e' un errore, e' la
--  grana della vista - ma va saputo prima di sommare questa vista per squadra.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_xg_giocatori AS
SELECT
    CONCAT(g.nome, ' ', g.cognome)                      AS giocatore,
    sq.nome                                             AS squadra,
    gp.ruolo                                            AS ruolo,
    COUNT(gp.id)                                        AS partite,
    SUM(gp.minuti)                                      AS minuti,
    SUM(gp.goal)                                        AS goal,
    SUM(gp.assist)                                      AS assist,
    SUM(gp.tiri)                                        AS tiri,
    SUM(gp.xg)                                          AS xg_totale,
    AVG(gp.xg)                                          AS xg_media,
    SUM(gp.xa)                                          AS xa_totale
FROM giocatori g
JOIN squadre sq          ON sq.id = g.squadra_id
JOIN giocatore_partita gp ON gp.giocatore_id = g.id
GROUP BY g.id, g.nome, g.cognome, sq.nome, gp.ruolo
ORDER BY xg_totale DESC;


-- -----------------------------------------------------------------------------
--  v_xg_squadra
--  "Una squadra crea e concede di piu' in casa o fuori?"
--
--  Aggregazione a due livelli: squadra e contesto. `xg_subiti` accanto a `xg`
--  e' la parte che si dimentica quasi sempre - una squadra che crea 1.8 xG a
--  partita concedendone 1.7 non e' una squadra offensiva, e' una squadra aperta.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_xg_squadra AS
SELECT
    s.nome                                              AS squadra,
    sk.ruolo                                            AS ruolo,
    COUNT(0)                                            AS partite,
    SUM(sk.goal_fatti)                                  AS goal_fatti,
    SUM(sk.goal_subiti)                                 AS goal_subiti,
    SUM(sk.xg)                                          AS xg_totale,
    AVG(sk.xg)                                          AS xg_media,
    SUM(sk.xg_subiti)                                   AS xg_subiti_totale,
    AVG(sk.xg_subiti)                                   AS xg_subiti_media,
    SUM(sk.punti)                                       AS punti
FROM squadre s
JOIN squadra_calendario sk ON sk.squadra_id = s.id
GROUP BY s.id, s.nome, sk.ruolo
ORDER BY xg_totale DESC;


-- -----------------------------------------------------------------------------
--  v_partite
--  "Il tabellone: chi ha giocato contro chi, e com'e' finita."
--
--  Il doppio JOIN sulla stessa tabella `squadre` e' il punto: `calendario` ha due
--  chiavi esterne verso squadre, quindi va unita due volte con due alias diversi
--  (sc = casa, st = trasferta). Senza alias distinti la query non e' scrivibile.
--
--  Il CASE traduce il punteggio nella notazione 1/X/2, che e' come i risultati
--  vengono letti da chi guarda il calcio.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_partite AS
SELECT
    c.giornata                                          AS giornata,
    c.data                                              AS data,
    sc.nome                                             AS squadra_casa,
    c.goal_casa                                         AS goal_casa,
    c.goal_trasferta                                    AS goal_trasferta,
    st.nome                                             AS squadra_trasferta,
    CASE
        WHEN c.goal_casa > c.goal_trasferta THEN '1'
        WHEN c.goal_casa = c.goal_trasferta THEN 'X'
        ELSE '2'
    END                                                 AS risultato,
    c.xg_casa                                           AS xg_casa,
    c.xg_trasferta                                      AS xg_trasferta
FROM calendario c
JOIN squadre sc ON sc.id = c.squadra_casa_id
JOIN squadre st ON st.id = c.squadra_trasferta_id;


-- -----------------------------------------------------------------------------
--  v_partite_squadra
--  "Il cammino di una squadra, partita per partita."
--
--  La vista piu' costosa delle nove: quattro JOIN, di cui tre sulla stessa
--  tabella `squadre` con alias diversi. Serve perche' "l'avversario" non e' una
--  colonna del database - e' l'altra squadra della partita, e va ricavata.
--
--  Il CASE su `sk.ruolo` sceglie quale dei due nomi mettere in colonna
--  `avversario`: se sto guardando la riga della squadra di casa, l'avversario e'
--  quella in trasferta, e viceversa. E' il pezzo che trasforma una tabella
--  orientata alla partita in una orientata alla squadra.
--
--  Due colonne che sembrano doppie e non lo sono:
--    `risultato` = com'e' finita la partita (1/X/2, punto di vista neutro)
--    `esito`     = com'e' finita PER QUESTA squadra (vittoria/pareggio/sconfitta)
--  Un '2' e' una vittoria o una sconfitta a seconda di chi guarda.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_partite_squadra AS
SELECT
    s.nome                                              AS squadra,
    sk.ruolo                                            AS ruolo,
    c.giornata                                          AS giornata,
    c.data                                              AS data,
    CASE sk.ruolo
        WHEN 'casa' THEN st.nome
        ELSE sc.nome
    END                                                 AS avversario,
    sk.goal_fatti                                       AS goal_fatti,
    sk.goal_subiti                                      AS goal_subiti,
    CASE
        WHEN c.goal_casa > c.goal_trasferta THEN '1'
        WHEN c.goal_casa = c.goal_trasferta THEN 'X'
        ELSE '2'
    END                                                 AS risultato,
    sk.risultato                                        AS esito,
    sk.xg                                               AS xg,
    sk.xg_subiti                                        AS xg_subiti,
    sk.punti                                            AS punti
FROM squadra_calendario sk
JOIN squadre s   ON s.id  = sk.squadra_id
JOIN calendario c ON c.id = sk.calendario_id
JOIN squadre sc  ON sc.id = c.squadra_casa_id
JOIN squadre st  ON st.id = c.squadra_trasferta_id;
