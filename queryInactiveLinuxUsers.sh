#!/bin/bash

# Obtener la fecha actual menos 90 días en formato Unix timestamp
cutoff_date=$(date -d '90 days ago' +%s)

# Iterar sobre cada usuario en el sistema
#for user in $(cut -d: -f1 /etc/passwd); do
UID_MIN=$(awk '/^UID_MIN/ {print $2}' /etc/login.defs)
UID_MAX=$(awk '/^UID_MAX/ {print $2}' /etc/login.defs)

USERS=$(awk -F: -v min=$UID_MIN -v max=$UID_MAX '{  if ($3 >= min && $3 <= max) print $1 }' /etc/passwd)

for user in $(awk -F: -v min=$UID_MIN -v max=$UID_MAX '{  if ($3 >= min && $3 <= max) print $1 }' /etc/passwd); do
#for user in $(cut -d: -f1 /etc/passwd); do

    # Obtener el último inicio de sesión del usuario
    last_login=$(lastlog -u "$user" | awk 'NR==2 {print $4, $5, $6, $7, $9}')
    #last_login=$(last "$user" | egrep -v "wtmp begins"|  awk 'NR==2 {print $4, $5, $6, $7}')

    #echo "$user lastl $last_login"
    # Si el usuario nunca ha iniciado sesión
    if [[ -z $last_login ]] || [[ $last_login =~ in ]]; then
        echo "$user nunca ha iniciado sesión"
    else
        # Convertir la fecha del último login al formato Unix timestamp
        login_time=$(date -d "$last_login" +%s 2>/dev/null)

        # Si la conversión de fecha es exitosa y la fecha es anterior al cutoff
        if [ $? -eq 0 ] && [ "$login_time" -lt "$cutoff_date" ]; then
           last_login_year=$(lastlog -u "$user" | awk 'NR==2 {print $3}')
           if [[  $last_login_year =~ Mon|Tue|Wed|Thu|Fri|Sat|Sun ]]; then
              last_login=$(lastlog -u "$user" | awk 'NR==2 {print $4, $5, $6, $7, $8}')
           fi
            echo "$user no se ha logueado en más de 90 días" "   $last_login"
        fi
    fi
done
