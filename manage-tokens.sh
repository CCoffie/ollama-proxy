#!/bin/bash

# Helper script to manage tokens for the Ollama Auth Proxy service

# --- Configuration ---

# The script attempts to read ADMIN_TOKEN and optionally INTERNAL_AUTH_PORT
# from the .env file in the current directory.
# INTERNAL_AUTH_PORT can also be set as an environment variable.

DEFAULT_AUTH_SERVICE_PORT="3000"
DOTENV_PATH="./.env"

# Read ADMIN_TOKEN from .env file
ADMIN_TOKEN=""
if [ -f "$DOTENV_PATH" ]; then
    ADMIN_TOKEN=$(grep '^ADMIN_TOKEN=' "$DOTENV_PATH" | cut -d '=' -f2)
    # Optionally read internal port from .env, fallback to ENV, then default
    INTERNAL_AUTH_PORT_DOTENV=$(grep '^INTERNAL_AUTH_PORT=' "$DOTENV_PATH" | cut -d '=' -f2)
fi

# Determine configuration for port (ENV VAR > .env > Default)
INTERNAL_AUTH_PORT="${INTERNAL_AUTH_PORT:-${INTERNAL_AUTH_PORT_DOTENV:-$DEFAULT_AUTH_SERVICE_PORT}}"

# Construct default URL based on INTERNAL_AUTH_PORT
DEFAULT_URL="http://localhost:${INTERNAL_AUTH_PORT}"


# --- Script Logic ---

# Function to print usage instructions
usage() {
  echo "Usage: $0 [service_url] <command> [name]"
  echo ""
  echo "Reads ADMIN_TOKEN and INTERNAL_AUTH_PORT from .env file."
  echo "INTERNAL_AUTH_PORT can be overridden by environment variable."
  echo ""
  echo "Arguments:"
  echo "  service_url  (Optional) URL of the auth service management endpoint."
  echo "               Defaults to http://localhost:<INTERNAL_AUTH_PORT> (currently $DEFAULT_URL)."
  echo "  command      The action to perform: list, add, delete."
  echo "  name         The name for the token (required for add and delete commands)."
  echo ""
  echo "Environment Variables (Required/Optional):"
  echo "  ADMIN_TOKEN        (Required) Your admin token."
  echo "  INTERNAL_AUTH_PORT (Optional) Port of the management service."
  echo ""
  echo "Examples:"
  echo "  List token names:  $0 list"
  echo "  Add token (generates key): $0 add my-service-name"
  echo "  Delete token:      $0 delete my-service-name"
  echo "  Use different URL: $0 http://192.168.1.100:3000 list"
  exit 1
}

# Check if ADMIN_TOKEN was read successfully
if [ -z "$ADMIN_TOKEN" ]; then
  echo "Error: ADMIN_TOKEN could not be read from $DOTENV_PATH or is empty."
  echo "Please ensure $DOTENV_PATH exists and contains a valid ADMIN_TOKEN line."
  usage
fi

# Function to process curl response
process_response() {
  local full_response="$1"
  local expected_status="$2"

  local http_status=$(echo "$full_response" | tail -n1 | sed 's/HTTP_STATUS://g')
  local response_body=$(echo "$full_response" | sed '$d')

  if [[ "$http_status" == "$expected_status" ]]; then
    # Success
    if [[ "$http_status" == "201" ]]; then # Handle successful 'add' specifically
        local token_name=$(echo "$response_body" | jq -r '.name // empty')
        local generated_token=$(echo "$response_body" | jq -r '.token // empty')
        if [[ -n "$token_name" && -n "$generated_token" ]]; then
             echo "Success: Added token for '${token_name}'."
             echo "Token: ${generated_token}   <-- SAVE THIS VALUE SECURELY!"
        else 
             # Fallback if JSON parsing failed for some reason
             echo "Success (Status ${http_status}), but could not parse response details. Raw response:"
             echo "$response_body"
        fi
    else 
        # For other success statuses (list, delete), just print formatted JSON
        echo "$response_body" | jq .
        if [ $? -ne 0 ]; then
            echo "Warning: Server returned success status ($http_status) but body was not valid JSON:"
            echo "$response_body"
        fi
    fi
  else
    # Failure
    echo "Error: Server returned status $http_status"
    echo "Response: $response_body"
    return 1
  fi
  return 0
}

# Argument Parsing
URL=$DEFAULT_URL
COMMAND=""
NAME_VALUE=""

# Check if the first argument is a command or a URL
if [[ "$1" == "list" || "$1" == "add" || "$1" == "delete" ]]; then
  # First arg is a command, use default URL
  COMMAND="$1"
  NAME_VALUE="$2"
else
  # First arg is not a command, assume it's a URL (if provided)
  if [ -n "$1" ]; then
     URL="$1"
     COMMAND="$2"
     NAME_VALUE="$3"
  else
     # No arguments provided or only URL provided without command
     usage
  fi
fi

# Validate command
case "$COMMAND" in
  list)
    echo "Listing token names from $URL..."
    # Use -w to append status code, capture output
    RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
         -H "Authorization: Bearer ${ADMIN_TOKEN}" \
         "${URL}/tokens")
    process_response "$RESPONSE" "200"
    echo ""
    ;;
  add)
    if [ -z "$NAME_VALUE" ]; then
      echo "Error: Token name is required for the 'add' command."
      usage
    fi
    echo "Adding token named '${NAME_VALUE}' via $URL..."
    
    RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
         -X POST "${URL}/tokens" \
         -H "Authorization: Bearer ${ADMIN_TOKEN}" \
         -H "Content-Type: application/json" \
         -d '{"name": "'"${NAME_VALUE}"'"}')
    
    process_response "$RESPONSE" "201"
    echo ""
    ;;
  delete)
    if [ -z "$NAME_VALUE" ]; then
      echo "Error: Token name is required for the 'delete' command."
      usage
    fi
    echo "Deleting token named '${NAME_VALUE}' via $URL..."
    # Capture curl output including status code
    RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
         -X DELETE "${URL}/tokens/${NAME_VALUE}" \
         -H "Authorization: Bearer ${ADMIN_TOKEN}")
    
    process_response "$RESPONSE" "200"
    echo ""
    ;;
  *)
    echo "Error: Invalid command '$COMMAND'"
    usage
    ;;
esac

exit 0 