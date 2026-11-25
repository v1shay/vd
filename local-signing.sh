#!/bin/bash
# Create the per-user signing key once. Only the public fingerprint is printed.
set -eu
umask 077
id_name="VD Local Code Signing"
login_keychain="$HOME/Library/Keychains/login.keychain-db"
fingerprint() {
    security find-certificate -c "$id_name" -p "$login_keychain" 2>/dev/null |
        openssl x509 -noout -fingerprint -sha1 2>/dev/null | awk -F= '{gsub(":","",$2);print $2}'
}
existing=$(fingerprint)
if [[ -n "$existing" ]]; then echo "$existing"; exit 0; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = sign
prompt = no
[dn]
CN = VD Local Code Signing
[sign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 -config "$tmp/cnf" -keyout "$tmp/key" -out "$tmp/crt" 2>"$tmp/keygen.log"
archive_password=$(openssl rand -hex 24)
export archive_password
openssl pkcs12 -export -inkey "$tmp/key" -in "$tmp/crt" -name "$id_name" -out "$tmp/id.p12" -passout env:archive_password -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$tmp/id.p12" -k "$login_keychain" -P "$archive_password" -T /usr/bin/codesign >&2
fingerprint
