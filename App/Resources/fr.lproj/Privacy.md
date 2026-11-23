# Informations de confidentialité de Moppo

## Fichiers et photos

Moppo analyse les fichiers du Mac pour trouver les éléments à nettoyer et mesurer l’espace occupé.
Moppo lit votre photothèque lorsque vous recherchez des photos en double.
Moppo ne transmet à Anguria ni les fichiers analysés, ni leurs chemins, ni les photos, ni le contenu de la photothèque.

## Données locales

Moppo stocke les réglages, les mesures de stockage et les reçus de suppression sur votre Mac.
Les reçus de suppression peuvent contenir les chemins d’origine des fichiers et leur emplacement dans la Corbeille.
Moppo utilise ces données pour l’historique et la remise en place.
Les résultats des commandes incluent la commande, le chemin cible, le code de sortie et une partie des messages d’erreur.
Moppo conserve ces résultats localement même si vous désactivez les reçus de remise en place.

## Ligne de commande

L’interface en ligne de commande conserve les rapports d’analyse localement pendant sept jours.
Après un enregistrement réussi, dix rapports valides au maximum sont conservés.
Les rapports peuvent contenir des noms de fichiers, des chemins, des tailles, des explications et des vérifications de l’identité des fichiers.
Les plans de nettoyage enregistrés contiennent des identifiants et expirent après un jour.
Un plan peut expirer plus tôt si son rapport source expire. Vingt plans valides au maximum sont conservés.
Les résultats des plans enregistrés contiennent des identifiants, des codes d’état et des totaux. Ils ne contiennent ni noms ni chemins de fichiers.
Les enregistrements des résultats expirent après sept jours.
Moppo conserve jusqu’à 100 enregistrements de résultats, dont des enregistrements distincts pour le début et la fin.
Moppo stocke ces données dans des dossiers privés sous ~/Library/Application Support/Moppo.
Les dossiers ont le mode d’accès 0700. Les fichiers ont le mode d’accès 0600.
Les données expirées sont inutilisables. Les fichiers peuvent subsister jusqu’au nettoyage suivant.
Les fichiers non valides et les sauvegardes peuvent être conservés au-delà de ces limites.
La sortie normale des commandes omet les noms, les chemins et les explications détaillées.
L’option --include-paths transmet ces informations à l’appelant.
Les résultats des suppressions d’un plan omettent les noms et les chemins.
La sortie réduite contient toujours les catégories, les tailles et les classifications de stockage.
L’interface en ligne de commande prise en charge ne renvoie pas le contenu des fichiers.
Un agent IA peut envoyer la sortie des commandes à son fournisseur.
Moppo ne contrôle pas ce fournisseur et ne garantit pas le traitement local par le modèle.
Les réglages et les règles du fournisseur déterminent la conservation et les communications ultérieures de ces données.

## Mises à jour de l’application

Moppo recherche automatiquement les mises à jour.
Vous pouvez désactiver la recherche automatique dans Réglages > Mises à jour.
Pendant cette recherche, Moppo contacte le site des mises à jour via HTTPS.
Le site reçoit votre adresse IP et les informations de connexion habituelles.
Sparkle compare la version installée de Moppo au flux de mises à jour.
Moppo désactive l’envoi du profil système par Sparkle.
Moppo demande votre confirmation avant d’installer une mise à jour.

## Services externes

Les requêtes à Photos et à iCloud utilisent les services Apple et votre compte Apple.
La suppression avec Homebrew utilise vos outils Homebrew déjà installés.
Homebrew peut contacter les sources de paquets selon ses propres réglages.
Lorsque Homebrew demande votre mot de passe, Moppo l’envoie directement à sudo et ne l’enregistre pas.
Pour vérifier la fusion d’un worktree, Moppo peut utiliser votre CLI GitHub et sa connexion existante.
Ces requêtes transmettent les noms des dépôts et les identifiants des commits à GitHub.
Elles ne transmettent ni les chemins locaux ni le contenu des fichiers.
Moppo ne conserve pas vos identifiants GitHub.

## Assistance

Vous pouvez envoyer une demande d’assistance à hello@anguria.studio.
Le rapport indique les versions de Moppo et de macOS.
Il ne contient ni chemins de fichiers, ni photos, ni journaux de suppression, ni mesures enregistrées.
Vous pouvez vérifier le rapport avant de l’envoyer.
Votre fournisseur de messagerie et Anguria reçoivent les informations que vous choisissez d’envoyer.

## Contact

Pour toute question sur la confidentialité, écrivez à hello@anguria.studio.
