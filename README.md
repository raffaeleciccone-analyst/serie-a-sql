# Serie A 2025/26 — lo schema SQL

Il livello dati dietro il [Football Scout Index](https://raffaeleciccone-analyst.github.io/serie-a-index/):
schema relazionale, le nove viste che alimentano le pagine, e le query analitiche che le viste
non sanno rispondere.

Sopra ogni vista c'e' la domanda a cui risponde; sotto ogni query c'e' cosa quella query
**non** dice.

| File | Cosa contiene |
|---|---|
| [`01_schema.sql`](01_schema.sql) | Le cinque tabelle, con il perche' di ogni scelta di modellazione |
| [`02_viste.sql`](02_viste.sql) | Le nove viste, una per una, con la domanda di business sopra |
| [`03_analisi.sql`](03_analisi.sql) | Sei query analitiche: funzioni finestra, CTE, self join |
| [`04_qualita_dati.sql`](04_qualita_dati.sql) | Dieci controlli di qualita', con l'esito dell'ultima esecuzione |

---

## Il modello

Uno schema a stella con **due tabelle dei fatti a grana diversa** che condividono la stessa
dimensione tempo. `calendario` e' il perno: una riga per partita, e tutto il resto ci si aggancia.

```mermaid
erDiagram
    squadre ||--o{ giocatori : "tessera"
    squadre ||--o{ calendario : "gioca in casa"
    squadre ||--o{ calendario : "gioca in trasferta"
    squadre ||--o{ squadra_calendario : "ha una riga per partita"
    calendario ||--|| squadra_calendario : "esattamente 2 righe"
    calendario ||--o{ giocatore_partita : "il dettaglio della partita"
    giocatori ||--o{ giocatore_partita : "una riga per presenza"

    squadre {
        int id PK
        varchar nome UK
    }
    giocatori {
        int id PK
        varchar nome
        varchar cognome
        int squadra_id FK
        enum ruolo "POR DIF CEN ATT"
    }
    calendario {
        int id PK
        int giornata
        datetime data
        int squadra_casa_id FK
        int squadra_trasferta_id FK
        int goal_casa
        int goal_trasferta
        float xg_casa
        float xg_trasferta
        int game_id_understat UK "chiave della fonte esterna"
    }
    squadra_calendario {
        int squadra_id PK_FK
        int calendario_id PK_FK
        enum ruolo "casa trasferta"
        int goal_fatti
        int goal_subiti
        float xg
        float xg_subiti
        enum risultato
        int punti
    }
    giocatore_partita {
        int id PK
        int giocatore_id FK
        int calendario_id FK
        int minuti
        int goal
        int assist
        int tiri
        float xg
        float xa
    }
```

**Volumi reali:** 20 squadre · 554 giocatori · 280 partite · 560 righe squadra-partita ·
**8.772 righe giocatore-partita**.

### Tre scelte di modellazione, e perche'

**`squadra_calendario` e' denormalizzata di proposito.** La stessa informazione si ricava da
`calendario` con una UNION fra il lato casa e il lato trasferta. Sta qui perche' meta' delle
domande di questo database sono *per squadra* e non *per partita*: con la UNION ogni classifica
costerebbe due scansioni, e la classifica e' la query piu' eseguita che esista.

**`punti` e `risultato` sono materializzati** anche se derivabili dai goal. La regola dei tre
punti e' una convenzione, non un fatto: tenerla in un solo posto (la procedura di caricamento)
evita che venga riscritta in ogni query, con il rischio che una la scriva diversa.

**Un giocatore non convocato non ha una riga.** Non e' una dimenticanza: *zero minuti* e *non
convocato* sono cose diverse, e l'assenza di riga le tiene distinte mentre uno 0 le
confonderebbe. Conseguenza pratica, da sapere prima di scrivere query: `COUNT(gp.id)` conta le
presenze, non le giornate.

---

## Le domande

Le nove viste rispondono a domande descrittive: chi ha segnato, come e' finita, chi sta davanti.
Le sei query in `03_analisi.sql` provano a rispondere a domande su cui **qualcuno deve poi
decidere qualcosa**:

| Domanda | Tecnica |
|---|---|
| Chi sta segnando piu' di quanto dovrebbe, e quindi calera'? | Aggregazione, `NULLIF`, normalizzazione per 90' |
| Chi sta arrivando in forma e chi sta scivolando? | Finestra mobile `ROWS BETWEEN 4 PRECEDING AND CURRENT ROW` |
| Quali squadre stanno sopra il proprio gioco? | CTE, `RANK() OVER`, confronto fra due classifiche |
| Quanto dipende una squadra da un solo giocatore? | `SUM() OVER (PARTITION BY)` accanto a un `GROUP BY` |
| Chi rende di piu' al netto di quanto gioca? | Per-90 con soglia minima |
| Contro chi ha giocato davvero ogni squadra? | Self join su `squadra_calendario` |

La riga **«NON dice»** sotto ognuna e' la parte che di solito manca. Un numero senza il suo limite
scritto accanto verra' usato per rispondere alla domanda sbagliata: la query sulla dipendenza da
un giocatore, per dire, segnala dove guardare, non conclude che sia un difetto.

---

## Su quali dati e' stato verificato

Le query non sono solo scritte: sono state **eseguite** su dati reali, trasferendo lo schema in
SQLite e caricandoci il contenuto dei dump `serie_a_25_26_*.sql` del motore: 20 squadre,
554 giocatori, 280 partite, 8.772 righe giocatore-partita.

**Quei dump sono una fotografia del 16 marzo 2026, non il database corrente.** Si riconosce
dallo schema: non hanno la colonna `season`, che il motore usa per separare le stagioni, ne' le
colonne `npxg`, `npg`, `xg_chain`, `xg_buildup` aggiunte in seguito a `giocatore_partita`.
Quindi lo schema in `01_schema.sql` e' quello di quella fotografia, ed e' un sottoinsieme di
quello vivo.

I dieci controlli in `04_qualita_dati.sql`, su quella fotografia, danno sei OK e quattro con
righe. Ecco cosa vuol dire ciascuno, perche' non tutti sono difetti:

**La colonna `giornata` (controlli 7 e 7b).** In quel dump non e' la giornata di campionato:
280 partite su 21 valori distinti, 16 partite nella "giornata 1", squadre che compaiono due
volte nello stesso valore a una settimana di distanza. **Risolto a monte:** il motore deriva la
giornata dall'invariante *una squadra gioca una sola partita per giornata*, in modo robusto a
rinvii e recuperi, e la usa solo come filtro di presentazione, mai nel calcolo dell'indice. Il
dump e' precedente a quel lavoro. Resta valida una regola pratica per chi scrive query su
questi dati: **ordinare per `data`**, che e' sempre affidabile. La query 2 in `03_analisi.sql`
e' scritta cosi' per questo.

**184 righe con un giocatore in una partita della squadra sbagliata (controllo 4).** Sono i
trasferimenti: l'anagrafica tiene una sola squadra per giocatore, quella corrente, mentre le
partite restano attribuite a chi le ha giocate. Non e' un errore di importazione, e' il modello
che non ha lo storico dei trasferimenti: un limite noto, da sapere prima di aggregare per
squadra.

**48 giocatori senza `ruolo` (controllo 6).** Su quella fotografia. Non ho potuto verificare lo
stato attuale: e' il tipo di difetto che non si manifesta, perche' quei giocatori spariscono in
silenzio da ogni query che filtra per ruolo, senza errori e senza comparire nei risultati,
per cui vale la pena rilanciare il controllo 6 sul database vivo.

---

## Un errore trovato eseguendo

Nelle query 1 e 5 la clausola era `HAVING minuti >= 450`, dove `minuti` e' un alias che si
chiama come la colonna `gp.minuti`. Quale dei due vince dipende dal motore: MySQL sceglie
l'alias, SQLite la colonna, e la stessa query restituisce due risultati diversi - in SQLite,
zero righe. Adesso l'aggregato e' scritto per esteso e non e' ambiguo per nessuno dei due: e' il tipo di
differenza che salta fuori eseguendo, e scrivendo la query e basta no.

---

## Far girare tutto

```bash
mysql -u utente -p -e "CREATE DATABASE serie_a CHARACTER SET utf8mb4;"
mysql -u utente -p serie_a < 01_schema.sql
mysql -u utente -p serie_a < 02_viste.sql
```

Serve **MySQL 8.0**: `03_analisi.sql` usa funzioni finestra e CTE.

I dati non sono in questo repository. Le pagine pubbliche del progetto pero' pubblicano
[il CSV completo](https://raffaeleciccone-analyst.github.io/serie-a-index/serie_a_tpi_2025-26.csv)
di tutti i giocatori qualificati con 49 colonne, e il `payload.json` del
[repo del sito](https://github.com/raffaeleciccone-analyst/serie-a-index) contiene giocatore per
giocatore ogni dimensione e punteggio: chi vuole rifare i conti puo' farlo da li'.

---

## Dove finisce questo livello e dove comincia il resto

Qui c'e' **il livello di misura**: le tabelle, le viste, i controlli. Il calcolo dell'indice
composito sta nel motore, in
[`serie-a-index-engine`](https://github.com/raffaeleciccone-analyst/serie-a-index-engine),
insieme alla suite di validazione.

Le quindici verifiche statistiche, comprese le tre che l'indice non supera, sono pubblicate
[qui](https://raffaeleciccone-analyst.github.io/serie-a-index/validazione.html).

**Il progetto e' stato costruito con l'aiuto di un assistente IA.** La domanda sopra ogni
vista e la riga "NON dice" sotto ogni query non sono decorazione: sono il motivo per cui ogni
scelta di modellazione e ogni limite dei dati si possono difendere uno per uno. Una scelta
che non si sa spiegare non serve a niente.

Fonti dei dati: xG e xA da [Understat](https://understat.com), anagrafica e valori da
Transfermarkt, agganciati per identificativo e non per nome. I nomi delle colonne sono in
italiano perche' lo e' il dominio, e tradurli avrebbe aggiunto un livello di traduzione fra la
domanda e la query senza far guadagnare niente a nessuno.
