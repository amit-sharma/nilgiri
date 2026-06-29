# https://www.thehacker.recipes/ad/movement/kerberos/delegations/constrained#without-protocol-transition
Set-ADComputer -Identity "fs-charlie$" -ServicePrincipalNames @{Add='HTTP/dc01-oscar.oscar.local'}
Set-ADComputer -Identity "fs-charlie$" -Add @{'msDS-AllowedToDelegateTo'=@('HTTP/dc01-oscar.oscar.local','HTTP/dc01-oscar')}
# Set-ADComputer -Identity "fs-charlie$" -Add @{'msDS-AllowedToDelegateTo'=@('CIFS/dc01-oscar.oscar.local','CIFS/dc01-oscar')}