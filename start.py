"""Wrapper to start the OpenFlake MCP server with streamable HTTP transport.

OpenFlake exposes the same API surface as ServiceNow, so the upstream
`mcp_server_servicenow` client drives it unchanged. The imports below keep
their upstream names on purpose — they are third-party identifiers, not ours
to rename. Only the configuration is OpenFlake's.
"""
import os
import uvicorn
from dotenv import load_dotenv
from mcp_server_servicenow.server import ServiceNowMCP, create_basic_auth

load_dotenv()

url = os.environ["OPENFLAKE_INSTANCE_URL"]
username = os.environ["OPENFLAKE_USERNAME"]
password = os.environ["OPENFLAKE_PASSWORD"]

auth = create_basic_auth(username, password)
server = ServiceNowMCP(url, auth)

app = server.mcp.streamable_http_app()

uvicorn.run(app, host="0.0.0.0", port=8000)
