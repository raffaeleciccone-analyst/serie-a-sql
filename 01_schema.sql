-- =============================================================================
--  Serie A 2025/26 - schema relazionale
--  MySQL 8.0
--
--  Cinque tabelle, uno schema a stella con due fatti che condividono la stessa
--  dimensione tempo (`calendario`): uno a grana squadra-partita, uno a grana
--  giocatore-partita.
--
--  Volumi reali del database da cui e' estratto:
--    squadre                20 righe
--    giocatori             554 righe
--    calendario            280 righe   (una per partita)
--    squadra_calendario    560 righe   (due per partita: casa e trasferta)
--    giocatore_partita   8.772 righe   (una per giocatore sceso in campo)
--
--  Per far girare tutto:
--    mysql -u utente -p -e "CREATE DATABASE serie_a CHARACTER SET utf8mb4;"
--    mysql -u utente -p serie_a < 01_schema.sql
--    mysql -u utente -p serie_a < 02_viste.sql
-- =============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;


-- -----------------------------------------------------------------------------
--  DIMENSIONE: squadre
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `squadre`;
CREATE TABLE `squadre` (
  `id`    int NOT NULL AUTO_INCREMENT,
  `nome`  varchar(100) NOT NULL,
  PRIMARY KEY (`id`),
  -- il nome e' unico: e' la chiave naturale usata per riconciliare le due fonti
  -- esterne (Understat per gli xG, Transfermarkt per l'anagrafica)
  UNIQUE KEY `nome` (`nome`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


-- -----------------------------------------------------------------------------
--  DIMENSIONE: giocatori
--  Il ruolo e' un ENUM e non una tabella a parte: quattro valori chiusi che non
--  cambiano mai. Una lookup table qui sarebbe un join in piu' senza un guadagno.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `giocatori`;
CREATE TABLE `giocatori` (
  `id`          int NOT NULL AUTO_INCREMENT,
  `nome`        varchar(100) NOT NULL,
  `cognome`     varchar(100) NOT NULL DEFAULT '',
  `squadra_id`  int NOT NULL,
  `ruolo`       enum('POR','DIF','CEN','ATT') DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_giocatori_squadra` (`squadra_id`),
  CONSTRAINT `fk_gioc_squadra` FOREIGN KEY (`squadra_id`)
    REFERENCES `squadre` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


-- -----------------------------------------------------------------------------
--  DIMENSIONE TEMPO: calendario
--  Una riga per partita. E' il perno dello schema: entrambe le tabelle dei fatti
--  ci si agganciano.
--
--  `game_id_understat` e' UNIQUE di proposito: e' l'identificativo della fonte
--  esterna, e il vincolo e' l'unica cosa che impedisce di importare due volte la
--  stessa partita. Agganciare per identificativo invece che per data e nomi
--  squadra e' quello che rende l'importazione ripetibile.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `calendario`;
CREATE TABLE `calendario` (
  `id`                    int NOT NULL AUTO_INCREMENT,
  `giornata`              int DEFAULT NULL,
  `data`                  datetime DEFAULT NULL,
  `squadra_casa_id`       int NOT NULL,
  `squadra_trasferta_id`  int NOT NULL,
  `goal_casa`             int DEFAULT '0',
  `goal_trasferta`        int DEFAULT '0',
  `xg_casa`               float DEFAULT '0',
  `xg_trasferta`          float DEFAULT '0',
  `game_id_understat`     int DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `game_id_understat` (`game_id_understat`),
  KEY `fk_cal_casa` (`squadra_casa_id`),
  KEY `fk_cal_tras` (`squadra_trasferta_id`),
  CONSTRAINT `fk_cal_casa` FOREIGN KEY (`squadra_casa_id`)
    REFERENCES `squadre` (`id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `fk_cal_tras` FOREIGN KEY (`squadra_trasferta_id`)
    REFERENCES `squadre` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


-- -----------------------------------------------------------------------------
--  FATTO 1: squadra_calendario  (grana: squadra x partita)
--
--  Due righe per ogni partita, una per squadra. La stessa informazione si
--  potrebbe ricavare da `calendario` con una UNION fra il lato casa e il lato
--  trasferta: e' denormalizzata di proposito, perche' meta' delle domande di
--  questo database sono "per squadra" e non "per partita", e con la UNION ogni
--  singola classifica costerebbe due scansioni.
--
--  `punti` e `risultato` sono derivabili dai goal. Sono materializzati perche'
--  la regola dei tre punti e' una convenzione, non un fatto: tenerla in un solo
--  punto (la procedura di caricamento) evita che venga riscritta in ogni query.
--
--  La chiave primaria composta (squadra_id, calendario_id) e' anche il vincolo
--  di integrita' vero: rende impossibile registrare due volte la stessa squadra
--  nella stessa partita.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `squadra_calendario`;
CREATE TABLE `squadra_calendario` (
  `squadra_id`     int NOT NULL,
  `calendario_id`  int NOT NULL,
  `ruolo`          enum('casa','trasferta') NOT NULL,
  `goal_fatti`     int DEFAULT '0',
  `goal_subiti`    int DEFAULT '0',
  `xg`             float DEFAULT '0',
  `xg_subiti`      float DEFAULT '0',
  `risultato`      enum('vittoria','pareggio','sconfitta') NOT NULL,
  `punti`          int DEFAULT '0',
  PRIMARY KEY (`squadra_id`,`calendario_id`),
  KEY `idx_sk_squadra` (`squadra_id`),
  KEY `idx_sk_calendario` (`calendario_id`),
  KEY `idx_sk_ruolo` (`ruolo`),
  CONSTRAINT `fk_sc_squadra` FOREIGN KEY (`squadra_id`)
    REFERENCES `squadre` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_sc_calendario` FOREIGN KEY (`calendario_id`)
    REFERENCES `calendario` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


-- -----------------------------------------------------------------------------
--  FATTO 2: giocatore_partita  (grana: giocatore x partita)
--
--  La tabella su cui gira tutto il resto. `uq_gp` e' il vincolo che regge
--  l'importazione: un giocatore compare al massimo una volta per partita, quindi
--  rilanciare l'import non duplica nulla.
--
--  Nota sulla grana: un giocatore che non e' sceso in campo NON ha una riga.
--  Non e' una svista - "zero minuti" e "non convocato" sono cose diverse, e
--  l'assenza di riga tiene distinte le due, mentre uno 0 le confonderebbe.
--  Conseguenza pratica: `COUNT(gp.id)` conta le presenze, non le giornate.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS `giocatore_partita`;
CREATE TABLE `giocatore_partita` (
  `id`             int NOT NULL AUTO_INCREMENT,
  `giocatore_id`   int NOT NULL,
  `calendario_id`  int NOT NULL,
  `ruolo`          enum('casa','trasferta') NOT NULL,
  `minuti`         int DEFAULT '0',
  `goal`           int DEFAULT '0',
  `assist`         int DEFAULT '0',
  `tiri`           int DEFAULT '0',
  `xg`             float DEFAULT '0',
  `xa`             float DEFAULT '0',
  `gialli`         int DEFAULT '0',
  `rossi`          int DEFAULT '0',
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_gp` (`giocatore_id`,`calendario_id`),
  KEY `idx_gp_giocatore` (`giocatore_id`),
  KEY `idx_gp_calendario` (`calendario_id`),
  CONSTRAINT `fk_gp_giocatore` FOREIGN KEY (`giocatore_id`)
    REFERENCES `giocatori` (`id`) ON DELETE CASCADE,
  CONSTRAINT `fk_gp_calendario` FOREIGN KEY (`calendario_id`)
    REFERENCES `calendario` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;


SET FOREIGN_KEY_CHECKS = 1;
