# Ollama Nginx Auth Proxy

Provides an Nginx proxy for Ollama with Bearer token authentication. This setup runs Nginx and the authentication service within a single container using **host networking**, making it suitable for scenarios like exposing Ollama (even if only listening on localhost) via a locally managed Cloudflare Tunnel.

## Quick Start

1.  **Configure**: Create a `.env` file by copying `.env.example` (`cp .env.example .env`). Set a secure `ADMIN_TOKEN` and verify/set `NGINX_PORT` and `INTERNAL_AUTH_PORT`.

2.  **Generate Secure Admin Token**: Run the following command to generate a secure `ADMIN_TOKEN` and update your `.env` file automatically:
    ```bash
    # Ensure openssl and sed are installed
    NEW_TOKEN=$(openssl rand -hex 32) && \
    sed -i "s/^ADMIN_TOKEN=.*/ADMIN_TOKEN=$NEW_TOKEN/" .env && \
    echo "ADMIN_TOKEN updated in .env"
    # Note for macOS users: You might need to use sed -i '' 's/.../' .env (add empty quotes after -i)
    ```
    *Verify the `NGINX_PORT` and `INTERNAL_AUTH_PORT` settings in `.env` are correct for your setup.*

3.  **Choose Run Method**: You can use Docker Compose (recommended) or direct `docker run`. Token data will be stored in a managed Docker volume named `ollama-proxy-data`.

    **Method A: Docker Compose (Recommended)**
    *   Uses the `docker-compose.yml` file which configures host networking and loads `.env`.
    *   Builds and runs the service:
        ```bash
        docker compose up -d --build
        ```

    **Method B: Direct `docker run`**
    *   Build the image first:
        ```bash
        docker build -t ollama-auth-proxy .
        ```
    *   Run using `--network host` and mount the named volume:
        ```bash
        # Create the volume first if it doesn't exist
        docker volume create ollama-proxy-data

        docker run -d --name ollama-proxy \
          --network host `# Use host networking` \
          --env-file .env \
          -v ollama-proxy-data:/data `# Mount named volume for token storage` \
          ollama-auth-proxy
        ```

4.  **Verify**: Check container logs (`docker logs ollama-proxy` or `docker compose logs`). Nginx should now be accessible on your host at **`http://localhost:NGINX_PORT`** (using the port defined in your `.env`, e.g., `http://localhost:8081`). 

    *   Ensure Ollama is running and listening on `127.0.0.1:11434` on the host.

## Token Management

Use the `manage-tokens.sh` script.

**Note:** This script requires `curl` and `jq` to be installed. It reads `ADMIN_TOKEN` and `INTERNAL_AUTH_PORT` directly from the `.env` file in the current directory.

```bash
# Install jq (e.g., on Debian/Ubuntu: sudo apt install jq)

chmod +x manage-tokens.sh

# Add a token (generates a key associated with the name)
./manage-tokens.sh add my-service-name
# -> SAVE THE GENERATED "token": "sk-proj-..." VALUE SECURELY! <-

# List token names
./manage-tokens.sh list

# Delete a token by name
./manage-tokens.sh delete my-service-name
```
*The script targets `http://localhost:INTERNAL_AUTH_PORT` by default (read from .env or defaults to 3000).* 

## Using the Proxy

Send requests to the proxy URL (**`http://localhost:NGINX_PORT`**, using the port from `.env`) with the generated `sk-proj-...` token. This example lists the available Ollama models:

```bash
# Replace NGINX_PORT if you changed it in .env (e.g., 8081)
# Replace sk-proj-... with your actual generated token
curl http://localhost:8081/v1/models \
  -H "Authorization: Bearer sk-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

## How it Works

*   A single Docker container runs Nginx and a Node.js auth service using Supervisor.
*   Uses **host networking** (`--network host` or `network_mode: host`), allowing direct access to host services and exposing container ports directly on the host.
*   Nginx listens on the **`NGINX_PORT`** (defined in `.env`, e.g., 8081) and becomes accessible directly on the host at that port.
*   Nginx proxies requests to `127.0.0.1:11434` (Ollama on host).
*   Nginx uses `auth_request` to ask the Node.js service (`localhost:INTERNAL_AUTH_PORT`) to validate the `Authorization: Bearer <token>` header.
*   The Node.js service:
    *   Compares the provided token against bcrypt hashes stored in `/data/tokens.json` (within the `ollama-proxy-data` Docker volume).
    *   Provides `/tokens` endpoints (protected by `ADMIN_TOKEN`) for managing named tokens.
*   Authenticated token names are included in Nginx access logs (`/var/log/nginx/access.log` inside the container).

## Logging

All major logs (Supervisor, Nginx Access/Error, Node.js Console) are directed to the container's standard output and standard error streams. 

You can view the combined, interleaved logs using:
```bash
docker compose logs -f ollama-proxy 
# or 
docker logs -f ollama-proxy 
```
