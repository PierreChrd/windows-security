
# Scripts de Renforcement Windows : BitLocker (TPM+PIN) & Message d’Avertissement de Connexion

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell)
![Windows](https://img.shields.io/badge/Windows-10%2F11%20%7C%20Server-0078D6?logo=windows)
![BitLocker](https://img.shields.io/badge/BitLocker-TPM%2BPIN-green)
![TPM Required](https://img.shields.io/badge/TPM-Required-yellow)
![Security](https://img.shields.io/badge/Security-Hardening-important)
[![Licence GPLv3](https://img.shields.io/badge/Licence-GPLv3-yellow)](LICENSE)
![MadeInFrance](https://img.shields.io/badge/Made_in-🟦⬜🟥-ffffff)

####  *🇺🇸 🇬🇧 English Version [README-ENGLISH.md](./README-ENGLISH.md)*

---

Deux scripts PowerShell prêts pour la production dans les environnements Windows professionnels :

- **`Manage-BitLocker.ps1`** — Active BitLocker sur le volume système avec **PIN de pré‑démarrage (TPM+PIN)**, sauvegarde la **clé de récupération**, et permet de **suspendre / reprendre / désactiver** via un paramètre `-Action`.
- **`Set-LogonWarning.ps1`** — Configure un **message d’avertissement légal** affiché **avant l’authentification** (connexion / déverrouillage). Peut aussi le supprimer.

> **Important :** Exécuter ces scripts dans une **console PowerShell en mode Administrateur**. Un redémarrage est requis pour que l’écran PIN BitLocker apparaisse.

---

## Table des matières
- [Aperçu](#aperçu)
- [Prérequis](#prérequis)
- [Script 1 : Manage-BitLocker.ps1](#script-1-manage-bitlockerps1)
  - [Fonctionnement](#fonctionnement)
  - [Paramètres](#paramètres)
  - [Exemples d’utilisation](#exemples-dutilisation)
  - [Notes & bonnes pratiques](#notes--bonnes-pratiques)
- [Script 2 : Set-LogonWarning.ps1](#script-2-set-logonwarningps1)
  - [Fonctionnement](#fonctionnement-1)
  - [Paramètres](#paramètres-1)
  - [Exemples d’utilisation](#exemples-dutilisation-1)
  - [Notes](#notes)
- [Dépannage](#dépannage)
- [Sécurité & conformité](#sécurité--conformité)
- [Déploiement (Intune / GPO)](#déploiement-intune--gpo)
- [Contribuer](#contribuer)
- [Licence](#licence)

---

## Aperçu
Ces scripts visent à standardiser le renforcement des postes Windows :

- **BitLocker avec TPM+PIN** assure une authentification pré‑démarrage pour sécuriser les volumes système.
- **Les messages d’avertissement** communiquent les règles d’utilisation et dissuadent les accès non autorisés.

Les deux scripts sont adaptés aux déploiements massifs (Intune, GPO, RMM, etc.).

---

## Prérequis
- Exécuter **PowerShell en Administrateur**.
- Windows **10/11 Pro/Enterprise/Education** ou **Windows Server** avec BitLocker disponible.
- (Optionnel) Autoriser temporairement l’exécution de scripts :
  ```powershell
  Set-ExecutionPolicy RemoteSigned -Scope Process
  ```

---

## Script 1 : `Manage-BitLocker.ps1`

### Fonctionnement
- Active BitLocker sur le volume système (`C:` par défaut) avec une **méthode de chiffrement configurable**.
- Ajoute un **protecteur TPM** + **PIN de pré‑démarrage** (TPM+PIN) → écran bleu BitLocker avant le boot.
- Garantit la présence d’un **protecteur de récupération (Recovery Password)**.
- Sauvegarde la **clé de récupération** localement et **optionnellement dans Entra ID (AAD)**.
- Gère **Disable (déchiffrement)**, **Suspend** et **Resume** via le paramètre `-Action`.

### Paramètres
- `-Action <Enable|Disable|Suspend|Resume>` — défaut `Enable`.
- `-MountPoint <Lecteur:>` — volume cible, défaut `C:`.
- `-EncryptionMethod <XtsAes128|XtsAes256|Aes128|Aes256>` — défaut `XtsAes256`.
- `-UsedSpaceOnly` — chiffrement rapide (espace utilisé seulement).
- `-BackupRecoveryToAAD` — sauvegarde dans Entra ID (si supporté).
- `-Quiet` — limite les sorties console.

### Exemples d’utilisation
```powershell
# Activer BitLocker + PIN pré-boot, XTS-AES 256, chiffrement espace utilisé
./Manage-BitLocker.ps1 -Action Enable -MountPoint C: -EncryptionMethod XtsAes256 -UsedSpaceOnly

# Activer BitLocker avec sauvegarde AAD
./Manage-BitLocker.ps1 -Action Enable -BackupRecoveryToAAD

# Suspendre temporairement la protection
./Manage-BitLocker.ps1 -Action Suspend

# Reprendre la protection
./Manage-BitLocker.ps1 -Action Resume

# Désactiver BitLocker (déchiffrement total)
./Manage-BitLocker.ps1 -Action Disable
```

### Notes & bonnes pratiques
- Un **TPM présent et prêt** est requis pour TPM+PIN.
- Le **PIN par défaut** est **numérique (4–20 chiffres)**.
- Pour autoriser un **PIN amélioré (alphanumérique)**, activer la GPO correspondante.
- Le prompt pré‑démarrage n’apparaît qu’après **redémarrage**.
- Sauvegarder la clé de récupération dans un **coffre sécurisé**.

---

## Script 2 : `Set-LogonWarning.ps1`

### Fonctionnement
- Ajoute une **bannière d’avertissement** (titre + message) affichée **avant l’authentification** en modifiant :
  - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\LegalNoticeCaption`
  - `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\LegalNoticeText`
- Peut aussi retirer la bannière avec `-Disable`.

### Paramètres
- `-Title <string>` — titre (défaut : *Security Warning*).
- `-Message <string>` — texte (défaut : *Authorized use only…*).
- `-Disable` — supprime la bannière.

### Exemples d’utilisation
```powershell
# Ajouter une bannière
./Set-LogonWarning.ps1 `
  -Title "SECURITY WARNING" `
  -Message "This system is for authorized use only. Unauthorized access is prohibited. If you are not authorized, disconnect immediately."

# Retirer la bannière
./Set-LogonWarning.ps1 -Disable
```

### Notes
- Visible à **Win+L**, connexion et redémarrage.
- Peut être imposé via **GPO**.
- Prévoir des **versions multilingues** si nécessaire.

---

## Dépannage
- **« This script must be run as Administrator »** → ouvrir PowerShell **en Admin**.
- **TPM absent/non prêt** → activer/initialiser dans l’UEFI.
- **Bannière non affichée** → déconnexion/redémarrage ou conflit GPO.
- **Sauvegarde AAD impossible** → cmdlet non supportée sur certains SKU.

---

## Sécurité & conformité
- Restreindre l’accès aux scripts.
- Protéger les **clés de récupération**.
- Tester sur un **group pilote** avant déploiement large.

---

## Déploiement (Intune / GPO)
**Intune**
- Déployer comme **script PowerShell** (64 bits, exécution admin). 
- Prévoir un **redémarrage** après l’activation BitLocker.

**GPO**
- Scripts de **démarrage machine** ou **Preferences > Registry** pour la bannière.
- GPO BitLocker pour forcer **TPM+PIN**.

---

## Contribuer
Contributions bienvenues. Proposez un ticket pour les améliorations ou modifications majeures.

---

## Licence
Ce projet est distribué sous licence **GNU General Public License v3.0**.  
Voir le fichier `LICENSE` pour les détails.

## Auteur
> Créé par **Pierre CHAUSSARD** — https://github.com/PierreChrd