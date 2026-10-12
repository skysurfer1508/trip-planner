from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    session_secret: str = "dev-only-change-me"
    db_path: str = "./data/trip.db"

    # Public address of the site, no trailing slash. The MCP resource URL is derived from it.
    public_base_url: str = "http://localhost:8095"

    # Authentik login for the website (OAuth2/OpenID provider "trip-web", confidential client).
    oidc_client_id: str = ""
    oidc_client_secret: str = ""
    oidc_server_metadata_url: str = ""
    oidc_redirect_uri: str = ""

    # Authentik provider for Claude's connector ("trip-claude", redirect URI https://claude.ai/api/mcp/auth_callback).
    # Its issuer URL is what Claude is pointed to; the client id is the `aud` claim access tokens must carry.
    mcp_issuer: str = ""
    mcp_client_id: str = ""
    # Fallback while OAuth is not working: a long random value that is part of the connector URL (/mcp-secret/<value>).
    # Empty = off. Anyone who knows the address can read and change everything.
    mcp_secret_path: str = ""
    # The Authentik user id (`sub`) the fallback door acts as, because it has no sign-in of its own. Without it the door stays closed.
    mcp_secret_sub: str = ""

    # Adds the Secure flag to the session cookie. Turn on for the public HTTPS deployment.
    session_https_only: bool = False

    # Local testing only: /login signs you in as a fake user without Authentik. Ignored unless the request comes from localhost.
    dev_login: bool = False


settings = Settings()
