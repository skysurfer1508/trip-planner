import os
import tempfile

# Must be set before app.main is imported: settings and the MCP apps are built at import time.
_dir = tempfile.mkdtemp(prefix="trip-web-test-")
os.environ.update({
    "DB_PATH": os.path.join(_dir, "trip.db"),
    "SESSION_SECRET": "test-secret",
    "DEV_LOGIN": "true",
    "PUBLIC_BASE_URL": "https://trip.example.org",
    "MCP_ISSUER": "https://auth.example.org/application/o/trip-claude/",
    "MCP_CLIENT_ID": "claude-client",
    "MCP_SECRET_PATH": "s3cret-value-for-tests",
    "MCP_SECRET_SUB": "dev",
})
