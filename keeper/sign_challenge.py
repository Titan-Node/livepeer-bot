#!/usr/bin/env python3
"""Sign a challenge file with an orchestrator keystore (EIP-191 personal_sign).

Equivalent to:  cast wallet sign --keystore <keystore> "$(cat <message-file>)"

Usage:
    python sign_challenge.py <keystore-file> <message-file>

Prompts for the keystore password (never echoed, never stored). Prints the
signing ADDRESS first so you can confirm it is the orchestrator the challenge
expects, then the 65-byte signature to paste. Signs the file's exact bytes --
nothing stripped, nothing appended -- as the EIP-191 personal_sign scheme
("\\x19Ethereum Signed Message:\\n" + length + bytes). This is an offchain
ownership proof: it is not a transaction and cannot move funds.

Dependency: eth-account (already present in this repo's keeper venv via web3).
"""

import getpass
import json
import sys
import types

# Windows Application Control can block bitarray's native DLL. eth_account only
# needs bitarray for mnemonic/HD-wallet features, which keystore signing never
# touches -- so if the real module cannot load, install an inert stub that lets
# the import chain through. Any accidental USE of the stub raises loudly.
try:
    import bitarray.util  # noqa: F401  (the DLL the policy actually blocks)
except ImportError:
    def _make_stub(name: str) -> types.ModuleType:
        mod = types.ModuleType(name)

        def _getattr(attr: str, _n=name):
            def _blocked(*_a, **_k):
                raise RuntimeError(f"{_n}.{attr} is stubbed out (bitarray DLL blocked)")
            return _blocked

        mod.__dict__["__getattr__"] = _getattr
        return mod

    if "bitarray" not in sys.modules:
        sys.modules["bitarray"] = _make_stub("bitarray")
    sys.modules["bitarray.util"] = _make_stub("bitarray.util")
    sys.modules["bitarray"].util = sys.modules["bitarray.util"]

from eth_account import Account
from eth_account.messages import encode_defunct


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    keystore_path, message_path = sys.argv[1], sys.argv[2]

    with open(message_path, "rb") as f:
        raw = f.read()  # exact bytes; the server defines the content, not us
    print(f"message file: {message_path} ({len(raw)} bytes)")

    with open(keystore_path) as f:
        keystore = json.load(f)
    password = getpass.getpass("keystore password: ")
    key = Account.decrypt(keystore, password)

    acct = Account.from_key(key)
    print(f"signing address: {acct.address}")
    print("  ^ confirm this matches the address the challenge expects BEFORE pasting")

    sig = Account.sign_message(encode_defunct(primitive=raw), key).signature.hex()
    if not sig.startswith("0x"):
        sig = "0x" + sig
    print(f"signature: {sig}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
