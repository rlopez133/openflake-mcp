FROM registry.access.redhat.com/ubi9/python-312:latest

USER 0

RUN dnf install -y git && dnf clean all

WORKDIR /app

# The upstream client stays servicenow-mcp: OpenFlake speaks the same API,
# so the same client drives it. Do not fork it just to rename things.
#
# The mcp<2 pin is mandatory: that repo is v1 code, and in mcp 2.x FastMCP
# was renamed to MCPServer. Unpinned installs crash with
# "ModuleNotFoundError: No module named 'mcp.server.fastmcp'".
# It appears twice because `pip install -e .` can pull mcp back up to 2.x.
#
# To pin upstream too, replace --branch master with a commit SHA:
#   git clone https://github.com/cooktheryan/servicenow-mcp.git . && git checkout <sha>
RUN git clone --branch master --depth 1 https://github.com/cooktheryan/servicenow-mcp.git . && \
    pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir "mcp>=1.28.0,<2" && \
    pip install --no-cache-dir -e . && \
    pip install --no-cache-dir "mcp>=1.28.0,<2"

USER 1001

COPY start.py /app/start.py

ENV FORWARDED_ALLOW_IPS="*"

EXPOSE 8000

ENTRYPOINT ["python", "/app/start.py"]
