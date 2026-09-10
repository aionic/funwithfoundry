"""Validate app-only Entra tokens independently of network or proxy headers."""

import json
import os
from functools import lru_cache
from uuid import UUID

import jwt


class IngestionError(Exception):
    def __init__(self, code: str, status: int) -> None:
        super().__init__(code)
        self.code = code
        self.status = status


def _guid(value: str) -> str:
    return str(UUID(value))


@lru_cache(maxsize=4)
def _keys(tenant: str) -> jwt.PyJWKClient:
    return jwt.PyJWKClient(
        f"https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys",
        cache_jwk_set=True,
        cache_keys=False,
        lifespan=3600,
        timeout=5,
    )


def authorize(authorization: str) -> None:
    if not isinstance(authorization, str) or len(authorization) > 16384:
        raise IngestionError("unauthorized", 401)
    parts = authorization.split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise IngestionError("unauthorized", 401)
    try:
        tenant = _guid(os.environ["INGEST_TENANT_ID"])
        audience = _guid(os.environ["INGEST_AUDIENCE"])
        configured = json.loads(os.environ["INGEST_AUTHORIZED_CALLERS"])
        if not isinstance(configured, dict) or not configured:
            raise ValueError("Missing caller allowlist")
        callers = {_guid(client): _guid(principal) for client, principal in configured.items()}
    except (KeyError, TypeError, ValueError, AttributeError):
        raise IngestionError("auth_not_configured", 503) from None

    encoded = parts[1]
    try:
        header = jwt.get_unverified_header(encoded)
        if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str):
            raise IngestionError("unauthorized", 401)
        signing_key = _keys(tenant).get_signing_key_from_jwt(encoded)
        claims = jwt.decode(
            encoded,
            signing_key.key,
            algorithms=["RS256"],
            audience=audience,
            issuer=f"https://login.microsoftonline.com/{tenant}/v2.0",
            leeway=30,
            options={
                "strict_aud": True,
                "require": ["exp", "nbf", "iat", "iss", "aud", "tid", "oid", "azp", "roles", "ver", "sub", "idtyp"],
            },
        )
    except jwt.PyJWKClientConnectionError:
        raise IngestionError("identity_unavailable", 503) from None
    except (jwt.InvalidTokenError, jwt.PyJWKClientError, ValueError, TypeError):
        raise IngestionError("unauthorized", 401) from None

    roles = claims.get("roles")
    if (
        claims.get("tid") != tenant
        or claims.get("ver") != "2.0"
        or claims.get("idtyp") != "app"
        or "scp" in claims
        or not isinstance(roles, list)
        or "Ingestion.Invoke" not in roles
        or not isinstance(claims.get("azp"), str)
        or callers.get(claims["azp"]) != claims.get("oid")
    ):
        raise IngestionError("forbidden", 403)
