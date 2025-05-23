#!/bin/bash
#This script will check to see if a user has an OTP token, and if not, create one and email the QR Code to the user
#This script works in RHEL9 and compatible OS 
#Thanks to https://gitea.tfmm.co/tfmm/freeipa-generate-otp-tokens.git, It is a improve script 
#set -x
#Mail Server Configuration - UPDATE THESE PARAMETERS
MAIL_SERVER="x.x.x.x."                  # Your SMTP server
MAIL_PORT="25"                          # SMTP port (25 for plain, 587 for TLS, 465 for SSL)
MAIL_USER=""                            # SMTP username (leave empty for no auth)
MAIL_PASS=""                            # SMTP password (leave empty for no auth)
MAIL_TLS="no"                           # Use TLS (yes/no)
MAIL_AUTH="no"                          # Use authentication (yes/no)
MAIL_SSL_VERIFIFY="ignore"              # Use without authentication

#Set Variables
#ARN of the secret which stores the FreeIPA Login credentials
AWS_SECRET_ARN="ARN of an AWS Secret holding your IPA user creds"
#Email address to notify
NOTIFY_EMAIL="freeipa-support@domain.com"
#IPA User, parsed from the secret
IPA_USER="admin"
#IPA Password, parsed from the secret
IPA_PASSWORD='aquipassw'
#IPA Server URL
IPA_URL="srvad01.domain.local"
#From email
FROM_EMAIL="notificaciones@domain.com"
#Set mail html file name
MAILFILE="/tmp/otptokenmail.html"
#Set QR Code image file name
QRFILE="/tmp/otptokenqr.png"

# Function to configure s-nail settings (modern mailx replacement)
configure_snail() {
    # Create s-nail configuration
    if [ "$MAIL_AUTH" = "yes" ] && [ -n "$MAIL_USER" ]; then
        # With authentication
        cat > ~/.mailrc << EOF
set v15-compat=yes
set smtp=smtp://${MAIL_USER}:${MAIL_PASS}@${MAIL_SERVER}:${MAIL_PORT}
set smtp-use-starttls=${MAIL_TLS}
set from="${FROM_EMAIL}"
set record=""
EOF
    else
        # Without authentication
        cat > ~/.mailrc << EOF
set v15-compat=yes
set smtp=smtp://${MAIL_SERVER}:${MAIL_PORT}
set from="${FROM_EMAIL}"
set smtp-auth=none
EOF
    fi
}

# Function to send email with attachment using s-nail (modern mailx)
send_email_snail() {
    local to_email="$1"
    local subject="$2"
    local html_content="$3"
    local attachment_file="$4"
    local attachment_name="${5:-otpqr.png}"

    # Configure s-nail settings
    configure_snail

    # Set environment variables for s-nail
    export MAILRC=~/.mailrc

    # Build MTA URL based on authentication requirement
    if [ "$MAIL_AUTH" = "yes" ] && [ -n "$MAIL_USER" ]; then
        MTA_URL="smtp://${MAIL_USER}:${MAIL_PASS}@${MAIL_SERVER}:${MAIL_PORT}"
    else
        MTA_URL="smtp://${MAIL_SERVER}:${MAIL_PORT}"
    fi

    if [ -n "$attachment_file" ] && [ -f "$attachment_file" ]; then
        # Send with attachment
        echo "$html_content" | s-nail -v \
            -s "$subject" \
            -S mta="$MTA_URL" \
            -S from="$FROM_EMAIL" \
            -S v15-compat=yes \
            -a "$attachment_file" \
            -M text/html \
            "$to_email"
    else
        # Send without attachment
        echo "$html_content" | s-nail -v \
            -s "$subject" \
            -S mta="$MTA_URL" \
            -S from="$FROM_EMAIL" \
            -S v15-compat=yes \
            -M text/html \
            "$to_email"
    fi
}

# Function to send email using traditional mailx (if available)
send_email_mailx_traditional() {
    local to_email="$1"
    local subject="$2"
    local html_content="$3"
    local attachment_file="$4"

    # Create traditional mailx config
    if [ "$MAIL_AUTH" = "yes" ] && [ -n "$MAIL_USER" ]; then
        # With authentication
        cat > ~/.mailrc << EOF
set smtp=${MAIL_SERVER}:${MAIL_PORT}
set smtp-use-starttls=${MAIL_TLS}
set smtp-auth=login
set smtp-auth-user=${MAIL_USER}
set smtp-auth-password=${MAIL_PASS}
set from="${FROM_EMAIL}"
EOF
    else
        # Without authentication
        cat > ~/.mailrc << EOF
set smtp=${MAIL_SERVER}:${MAIL_PORT}
set smtp-use-starttls=${MAIL_TLS}
set from="${FROM_EMAIL}"
EOF
    fi

    if [ -n "$attachment_file" ] && [ -f "$attachment_file" ]; then
        # Send with attachment using uuencode
        (
            echo "$html_content"
            echo ""
            echo "Please find the QR code attached below:"
            uuencode "$attachment_file" "otpqr.png"
        ) | mailx -s "$subject" "$to_email"
    else
        # Send without attachment
        echo "$html_content" | mailx -s "$subject" "$to_email"
    fi
}

# Alternative function using mail command with external SMTP configuration
send_email_mail_external() {
    local to_email="$1"
    local subject="$2"
    local html_content="$3"
    local attachment_file="$4"

    # Create temporary msmtp config for this session
    local msmtp_config=$(mktemp)
    cat > "$msmtp_config" << EOF
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile ~/.msmtp.log

account default
host ${MAIL_SERVER}
port ${MAIL_PORT}
from ${FROM_EMAIL}
user ${MAIL_USER}
password ${MAIL_PASS}
EOF

    # Set sendmail to use msmtp
    export MSMTP_CONFIG="$msmtp_config"

    if [ -n "$attachment_file" ] && [ -f "$attachment_file" ]; then
        # Create MIME message with attachment
        local temp_file=$(mktemp)
        cat > "$temp_file" << EOF
Subject: ${subject}
From: ${FROM_EMAIL}
To: ${to_email}
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY"

--BOUNDARY
Content-Type: text/html; charset="utf-8"

${html_content}
--BOUNDARY
Content-Type: image/png; name="otpqr.png"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="otpqr.png"

$(base64 "$attachment_file")
--BOUNDARY--
EOF
        msmtp -C "$msmtp_config" "$to_email" < "$temp_file"
        rm -f "$temp_file"
    else
        # Send simple HTML email
        (
            echo "Subject: $subject"
            echo "From: $FROM_EMAIL"
            echo "To: $to_email"
            echo "Content-Type: text/html; charset=utf-8"
            echo ""
            echo "$html_content"
        ) | msmtp -C "$msmtp_config" "$to_email"
    fi

    rm -f "$msmtp_config"
}

#Set kerberos ticket
echo $IPA_PASSWORD | kinit $IPA_USER

#List users not in service account groups
USERS=$(ipa user-find --not-in-groups=service-accounts --not-in-groups=admin-svc-accts --disabled=false | grep "User login:" | awk '{print $NF}')

#Function to create the token and email it
create_otptoken() {
    echo "Creating OTP token for user: $USER"

    # Create the OTP token
    TOKEN_URI=$(ipa otptoken-add --owner=$USER --no-qrcode --type=totp --algo=sha256 --digits=6 --desc="Created Automatically on $(date +"%Y-%m-%d_%H-%M-%S")" | grep URI | awk -F" " '{print $NF}')

    if [ -z "$TOKEN_URI" ]; then
        echo "Error: Failed to create OTP token for $USER"
        return 1
    fi

    # Clear mail file and remove old QR code
    cat /dev/null > $MAILFILE
    rm -f $QRFILE

    # Generate QR code
    /usr/bin/qrencode "${TOKEN_URI}" -o $QRFILE

    if [ ! -f "$QRFILE" ]; then
        echo "Error: Failed to generate QR code for $USER"
        return 1
    fi

    # Create HTML email content
    cat > $MAILFILE << EOF
<html>
<body>
<p>Congratulations, a new OTP Token has been created for your use in the FreeIPA authentication system.</p>
<p>Please scan the attached QR code with the OTP Mobile Application on your device of choice.</p>
<p>Popular OTP applications include:</p>
<ul>
<li>Google Authenticator</li>
<li>FreeOTP</li>
</ul>
<p>If the QR code attachment does not work, you can manually enter this URI in your OTP application:</p>
<p><code>${TOKEN_URI}</code></p>
<p>For support, please contact the IT team.</p>
</body>
</html>
EOF

    # Set email subject
    SUBJECT="FreeIPA OTP Token Created for $USER"

    # Get user email
    USER_EMAIL=$(ipa user-find $USER | grep Email | awk '{print $NF}')

    # Check if user email is valid
    if [ -z "$USER_EMAIL" ] || [ "$USER_EMAIL" = "Email:" ]; then
        echo "Warning: No email found for user $USER, using notification email instead"
        USER_EMAIL="$NOTIFY_EMAIL"
    fi

    echo "Sending OTP information to user: $USER_EMAIL"

    # Send email to user with QR code attachment
    MAIL_CONTENT="$(<$MAILFILE)"

        # Try s-nail first (modern), fallback to traditional mailx
    if command -v s-nail > /dev/null 2>&1; then
        echo "Using s-nail for email delivery"
        send_email_snail "$USER_EMAIL" "$SUBJECT" "$MAIL_CONTENT" "$QRFILE"
    elif command -v mailx > /dev/null 2>&1; then
        echo "Using traditional mailx for email delivery"
        send_email_mailx_traditional "$USER_EMAIL" "$SUBJECT" "$MAIL_CONTENT" "$QRFILE"
    else
        echo "Error: No mail command available (s-nail or mailx)"
        return 1
    fi

    if [ $? -eq 0 ]; then
        echo "Email sent successfully to $USER_EMAIL"
    else
        echo "Error: Failed to send email to $USER_EMAIL"
        return 1
    fi

    # Send notification to admin
    ADMIN_SUBJECT="FreeIPA OTP Token Created - Notification"
    ADMIN_CONTENT="<html><body><p>A new OTP Token has been created for user <strong>${USER}</strong>, and information has been emailed to them at <strong>${USER_EMAIL}</strong>.</p><p>Token created on: $(date)</p></body></html>"

    echo "Sending notification to administrator: $NOTIFY_EMAIL"

    # Use the same mail method as above
    if command -v s-nail > /dev/null 2>&1; then
        send_email_snail "$NOTIFY_EMAIL" "$ADMIN_SUBJECT" "$ADMIN_CONTENT"
    elif command -v mailx > /dev/null 2>&1; then
        send_email_mailx_traditional "$NOTIFY_EMAIL" "$ADMIN_SUBJECT" "$ADMIN_CONTENT"
    else
        echo "Error: No mail command available for admin notification"
    fi

    if [ $? -eq 0 ]; then
        echo "Notification sent successfully to $NOTIFY_EMAIL"
    else
        echo "Warning: Failed to send notification to $NOTIFY_EMAIL"
    fi

    # Clean up temporary files
    rm -f "$MAILFILE" "$QRFILE"
}

# Main loop to process users
echo "Starting OTP token check for users..."
echo "Found users: $USERS"

for USER in $USERS; do

        if [ $USER != "admin" ]; then
                echo "Processing user: $USER"

                #Check to see if user has OTP token
                ipa otptoken-find --owner=$USER > /dev/null 2>&1
                otp_ec=$?

                #If no otp token, create it and send email
                if [[ $otp_ec != 0 ]]; then
                        echo "No token found for $USER, creating one and sending it to the user..."
                        create_otptoken
                        if [ $? -eq 0 ]; then
                                echo "Successfully created and sent OTP token for $USER"
                        else
                                echo "Failed to create or send OTP token for $USER"
                        fi
                else
                        echo "$USER has a token, no need to create a new one."
                fi

        fi
        echo "---"
done

echo "OTP token processing completed."

# Clean up kerbero
