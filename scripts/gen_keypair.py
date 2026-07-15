"""
gen_keypair.py — generate an RSA keypair for Snowflake key-pair authentication.

Run once:
    py scripts/gen_keypair.py

Writes the private key to rsa_key.p8 (gitignored) and prints the ALTER USER
statement to paste into Snowsight.

Note: this generates an UNENCRYPTED private key. That's fine for a 30-day trial
holding public data. In production you'd encrypt it with a passphrase and keep
the passphrase in a secrets manager.
"""

from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

PROJECT_ROOT = Path(__file__).resolve().parent.parent
KEY_PATH = PROJECT_ROOT / "rsa_key.p8"

if KEY_PATH.exists():
    print(f"{KEY_PATH} already exists. Delete it first if you want a new key.")
    raise SystemExit(1)

print("Generating 2048-bit RSA keypair...")
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# --- private key -> disk ---
private_pem = key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
)
KEY_PATH.write_bytes(private_pem)

# --- public key -> stdout, stripped for ALTER USER ---
public_pem = key.public_key().public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
).decode()

# Snowflake wants the base64 body only, no PEM header/footer, no newlines.
public_body = "".join(
    line for line in public_pem.splitlines()
    if not line.startswith("-----")
)

print(f"\nPrivate key written to: {KEY_PATH}")
print("  ^ NEVER commit this. Confirm rsa_key.p8 is in .gitignore.\n")
print("=" * 70)
print("Paste this into a Snowsight worksheet:\n")
print(f"USE ROLE ACCOUNTADMIN;")
print(f"ALTER USER SQLISH SET RSA_PUBLIC_KEY='{public_body}';")
print("=" * 70)
