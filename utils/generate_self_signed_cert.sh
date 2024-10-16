#!/bin/bash

CERT_DIR="./certs"
CERT_KEY="$CERT_DIR/server.key"
CERT_CSR="$CERT_DIR/server.csr"
CERT_CRT="$CERT_DIR/server.crt"
CERT_DAYS=3650

mkdir -p "$CERT_DIR"

openssl genpkey -algorithm RSA -out "$CERT_KEY" -pkeyopt rsa_keygen_bits:2048
if [ $? -ne 0 ]; then
    echo "Failed to generate private key."
    exit 1
fi

openssl req -new -key "$CERT_KEY" -out "$CERT_CSR" -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=localhost"
if [ $? -ne 0 ]; then
    echo "Failed to generate CSR."
    exit 1
fi

openssl x509 -req -days "$CERT_DAYS" -in "$CERT_CSR" -signkey "$CERT_KEY" -out "$CERT_CRT"
if [ $? -ne 0 ]; then
    echo "Failed to generate self-signed certificate."
    exit 1
fi

echo "Generated the following files in $CERT_DIR:"
echo "Private Key: $CERT_KEY"
echo "CSR: $CERT_CSR"
echo "Certificate: $CERT_CRT"

rm "$CERT_CSR"

echo "Self-signed certificate generation completed successfully."