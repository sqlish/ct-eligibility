"""

How to reach Snowflake.

Uses key-pair authentication.

    python scripts/snow_connect.py   # run directly to self-test the connection

"""

import os
import sys
from pathlib import Path

import snowflake.connector
from cryptography.hazmat.primitives import serialization
from dotenv import load_dotenv

PROJECT_ROOT = Path(__file__).resolve().parent.parent  # repo root, two levels up from this file
load_dotenv(PROJECT_ROOT / ".env")                     # pull Snowflake credentials out of the .env file

# env vars that must be present, or we can't build a connection
REQUIRED = [
    "SNOWFLAKE_ACCOUNT",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
    "SNOWFLAKE_DATABASE",
    "SNOWFLAKE_SCHEMA",
]

DEFAULT_KEY_PATH = PROJECT_ROOT / "rsa_key.p8"  # private key location, unless .env overrides it


def _load_private_key():
    """Read the RSA private key from disk and return it in the format the connector needs."""
    key_path = Path(os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH", DEFAULT_KEY_PATH))
    if not key_path.exists():
        print(f"Private key not found at {key_path}")
        print("Run: py scripts/gen_keypair.py")
        sys.exit(1)

    passphrase = os.getenv("SNOWFLAKE_PRIVATE_KEY_PASSPHRASE")
    p_key = serialization.load_pem_private_key(
        key_path.read_bytes(),
        password=passphrase.encode() if passphrase else None,
    )

    # Connector wants DER-encoded PKCS8 bytes.
    return p_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def get_connection():
    """Open and return a Snowflake connection using key-pair auth."""
    missing = [k for k in REQUIRED if not os.getenv(k)]
    if missing:
        print(f"Missing from .env: {', '.join(missing)}")
        sys.exit(1)

    return snowflake.connector.connect(
        account=os.getenv("SNOWFLAKE_ACCOUNT"),
        user=os.getenv("SNOWFLAKE_USER"),
        role=os.getenv("SNOWFLAKE_ROLE"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE"),
        database=os.getenv("SNOWFLAKE_DATABASE"),
        schema=os.getenv("SNOWFLAKE_SCHEMA"),
        private_key=_load_private_key(),
    )


if __name__ == "__main__":
    print(f"Connecting to {os.getenv('SNOWFLAKE_ACCOUNT')} as {os.getenv('SNOWFLAKE_USER')}...")

    try:
        conn = get_connection()
    except Exception as e:
        print(f"\nConnection FAILED:\n  {type(e).__name__}: {e}")
        sys.exit(1)

    try:
        cur = conn.cursor()
        cur.execute("""
            SELECT CURRENT_USER(), CURRENT_ROLE(), CURRENT_WAREHOUSE(),
                   CURRENT_DATABASE(), CURRENT_SCHEMA()
        """)
        user, role, wh, db, schema = cur.fetchone()

        print("\nConnected via key-pair auth.")
        print(f"  user      : {user}")
        print(f"  role      : {role}")
        print(f"  warehouse : {wh}")
        print(f"  database  : {db}")
        print(f"  schema    : {schema}")

        cur.execute("SELECT COUNT(*) FROM ct_trials.raw.studies_raw")
        print(f"\n  studies_raw rows: {cur.fetchone()[0]}")

    finally:
        conn.close()