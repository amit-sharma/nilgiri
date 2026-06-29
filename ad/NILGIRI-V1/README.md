# GOAD-Light

![GOAD Light overview](../../docs/img/GOAD-Light_schema.png)

This is a light version of goad without the essos domain. This lab was build for computer with less performance.
Missing scenarios:
- cross forest exploitation (no more external forest)
- mssql trusted link
- some old computer vulnerabilities (zero logon, petitpotam unauthent,...)
- ESC4, ESC2/3

### Servers
This lab is actually composed of three virtual machines:
- **dc01-charlie** : DC01  running on Windows Server 2019 (with windefender enabled by default)
- **dc01-oscar**   : DC02  running on Windows Server 2019 (with windefender enabled by default)
- **fs-charlie**  : SRV02 running on Windows Server 2019 (with windefender **disabled** by default)

#### domain : oscar.local
- **dc01-oscar**     : DC01
- **fs-charlie**    : SRV02 : MSSQL / IIS

#### domain : charlie.local
- **dc01-charlie**   : DC02


The lab setup is automated using vagrant and ansible automation tools.
You can change the vm version in the Vagrantfile according to Stefan Scherer vagrant repository : https://app.vagrantup.com/StefanScherer


### Users/Groups and associated vulnerabilites/scenarios

- You can find a lot of the available scenarios on [https://mayfly277.github.io/categories/ad/](https://mayfly277.github.io/categories/ad/)

NORTH.CHARLIE.LOCAL
- STARKS:              RDP on WINTERFELL AND CASTELBLACK
  - arya.stark:        Execute as user on mssql
  - eddard.stark:      DOMAIN ADMIN NORTH/ (bot 5min) LLMRN request to do NTLM relay with responder
  - catelyn.stark:     
  - robb.stark:        bot (3min) RESPONDER LLMR
  - sansa.stark:       
  - brandon.stark:     ASREP_ROASTING
  - rickon.stark:      
  - theon.greyjoy:
  - jon.snow:          mssql admin / KERBEROASTING / group cross domain / mssql trusted link
  - hodor:             PASSWORD SPRAY (user=password)
- NIGHT WATCH:         RDP on CASTELBLACK
  - samwell.tarly:     Password in ldap description / mssql execute as login
                       GPO abuse (Edit Settings on "STARKWALLPAPER" GPO)
  - jon.snow:          (see starks)
  - jeor.mormont:      (see mormont)
- MORMONT:             RDP on CASTELBLACK
  - jeor.mormont:      ACL writedacl-writeowner on group Night Watch
- AcrossTheSea :       cross forest group

CHARLIE.LOCAL
- LANISTERS
  - tywin.lannister:   ACL forcechangepassword on jaime.lanister
  - jaime.lannister:   ACL genericwrite-on-user joffrey.baratheon
  - tyron.lannister:   ACL self-self-membership-on-group Small Council
  - cersei.lannister:  DOMAIN ADMIN CHARLIE
- BARATHEON:           RDP on KINGSLANDING
  - robert.baratheon:  DOMAIN ADMIN CHARLIE
  - joffrey.baratheon: ACL Write DACL on tyron.lannister
  - renly.baratheon:
  - stannis.baratheon: ACL genericall-on-computer dc01-charlie / ACL writeproperty-self-membership Domain Admins
- SMALL COUNCIL :      ACL add Member to group dragon stone / RDP on KINGSLANDING
  - petyer.baelish:    ACL writeproperty-on-group Domain Admins
  - lord.varys:        ACL genericall-on-group Domain Admins / Acrossthenarrossea
  - maester.pycelle:   ACL write owner on group Domain Admins
- DRAGONSTONE :        ACL Write Owner on KINGSGUARD
- KINGSGUARD :         ACL generic all on user stannis.baratheon
- AccorsTheNarrowSea:       cross forest group


### Computers Users and group permissions

- CHARLIE
  - DC01 : dc01-charlie.charlie.local (Windows Server 2019) (CHARLIE DC)
    - Admins : robert.baratheon (U), cersei.lannister (U)
    - RDP: Small Council (G)

- NORTH
  - DC02 : dc01-oscar.oscar.local (Windows Server 2019) (NORTH DC)
    - Admins : eddard.stark (U), catelyn.stark (U), robb.stark (U)
    - RDP: Stark(G)

  - SRV02 : fs-charlie.essos.local (Windows Server 2019) (IIS, MSSQL, SMB share)
    - Admins: jeor.mormont (U)
    - RDP: Night Watch (G), Mormont (G), Stark (G)
    - IIS : allow asp upload, run as NT Authority/network
    - MSSQL:
      - admin : jon.snow
      - impersonate : 
        - execute as login : samwel.tarlly -> sa
        - execute as user : arya.stark -> dbo
