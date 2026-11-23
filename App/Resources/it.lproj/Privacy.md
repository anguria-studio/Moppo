# Informazioni sulla privacy di Moppo

## File e foto

Moppo analizza i file sul Mac per trovare elementi da rimuovere e misurare lo spazio occupato.
Moppo legge la libreria foto quando cerchi foto duplicate.
Moppo non invia ad Anguria i file analizzati, i relativi percorsi, le foto o il contenuto della libreria foto.

## Registri locali

Moppo salva sul Mac le impostazioni, le misurazioni dello spazio e le ricevute di rimozione.
Le ricevute di rimozione possono contenere i percorsi originali dei file e le relative posizioni nel Cestino.
Moppo usa questi dati per la cronologia e per il ripristino.
I risultati dei comandi includono il comando, il percorso di destinazione, il codice di uscita e una parte dei messaggi di errore.
Moppo conserva questi risultati sul Mac anche se disattivi le ricevute per il ripristino.

## Riga di comando

L’interfaccia a riga di comando conserva i rapporti di analisi sul Mac per sette giorni.
Dopo ogni salvataggio riuscito, rimangono al massimo dieci rapporti validi.
I rapporti possono contenere nomi di file, percorsi, dimensioni, spiegazioni dell’analisi e verifiche dell’identità dei file.
I piani di pulizia salvati contengono identificatori e scadono dopo un giorno.
Un piano può scadere prima se scade il rapporto su cui si basa. Rimangono al massimo venti piani validi.
I risultati dei piani salvati contengono identificatori, codici di stato e conteggi. Non contengono nomi o percorsi dei file.
I registri dei risultati scadono dopo sette giorni.
Moppo conserva al massimo 100 registri dei risultati, inclusi registri distinti per l’avvio e il risultato finale.
Moppo salva questi dati in cartelle private in ~/Library/Application Support/Moppo.
Le cartelle hanno il modo di accesso 0700. I file dei registri hanno il modo di accesso 0600.
Alla scadenza, i dati non sono più utilizzabili. I file possono rimanere fino alla successiva pulizia dell’archivio.
I file non validi e le copie di backup possono rimanere oltre questi limiti.
L’output normale dei comandi omette nomi, percorsi e spiegazioni dettagliate.
L’opzione --include-paths trasmette queste informazioni a chi esegue il comando.
I risultati di rimozione di un piano omettono nomi e percorsi.
L’output ridotto contiene comunque categorie, dimensioni e classificazioni dello spazio.
L’interfaccia a riga di comando supportata non restituisce il contenuto dei file.
Un agente di IA può inviare l’output dei comandi al proprio fornitore.
Moppo non controlla il fornitore e non garantisce che il modello elabori i dati in locale.
Le impostazioni e le norme del fornitore determinano la conservazione e l’ulteriore condivisione dei dati.

## Aggiornamenti dell’app

Moppo verifica automaticamente la disponibilità di aggiornamenti.
Puoi disattivare la verifica automatica in Impostazioni > Aggiornamenti.
Durante la verifica, Moppo contatta il sito degli aggiornamenti tramite HTTPS.
Il sito riceve il tuo indirizzo IP e le normali informazioni di connessione.
Sparkle confronta la versione installata di Moppo con il feed degli aggiornamenti.
Moppo disattiva l’invio del profilo di sistema da parte di Sparkle.
Moppo chiede conferma prima di installare un aggiornamento.

## Servizi esterni

Le richieste di Foto e iCloud utilizzano i servizi Apple e il tuo Apple Account.
La rimozione tramite Homebrew utilizza gli strumenti di Homebrew già installati.
Homebrew può contattare le origini dei pacchetti in base alle proprie impostazioni.
Quando Homebrew richiede la password, Moppo la invia direttamente a sudo e non la salva.
Per verificare il merge di un worktree, Moppo può usare il client GitHub già installato e la relativa sessione attiva.
Queste richieste inviano a GitHub i nomi dei repository e gli identificatori dei commit.
Non inviano i percorsi locali o il contenuto dei file.
Moppo non salva le credenziali di GitHub.

## Assistenza

Puoi inviare una richiesta di assistenza a hello@anguria.studio.
Il rapporto include le versioni di Moppo e macOS.
Non contiene percorsi di file, foto, registri di rimozione o misurazioni salvate.
Puoi controllare il rapporto prima di inviarlo.
Il tuo fornitore di posta e Anguria ricevono le informazioni che decidi di inviare.

## Contatti

Per domande sulla privacy, scrivi a hello@anguria.studio.
