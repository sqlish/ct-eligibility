"""

Generate an RSA keypair for Snowflake key-pair authentication.

Run once. Writes the private key to rsa_key.p8 (gitignored) and prints the
ALTER USER statement to paste into Snowsight.

    python scripts/gen_keypair.py

Note: this generates an UNENCRYPTED private key.

"""

from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

PROJECT_ROOT = Path(__file__).resolve().parent.parent  # repo root, two levels up from this file
KEY_PATH = PROJECT_ROOT / "rsa_key.p8"                 # where the private key gets written

if KEY_PATH.exists():
    print(f"{KEY_PATH} already exists. Delete it first if you want a new key.")
    raise SystemExit(1)

print("Generating 2048-bit RSA keypair...")
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# save the private key to disk (secret, keep it local)
private_pem = key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption(),
)
KEY_PATH.write_bytes(private_pem)

# the public key goes to Snowflake (safe to share) via the ALTER USER statement
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
