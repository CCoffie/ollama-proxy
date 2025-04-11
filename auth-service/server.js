const express = require('express');
const bodyParser = require('body-parser');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const bcrypt = require('bcrypt');

const app = express();
const port = process.env.INTERNAL_AUTH_PORT || 3000;
const adminToken = process.env.ADMIN_TOKEN;
const internalTokensFilePath = '/data/tokens.json';
const internalTokensDirPath = '/data';
const saltRounds = 10; // Cost factor for bcrypt
const tokenPrefix = "sk-proj-"; // OpenAI-like prefix
const tokenLength = 48; // Length of the random part of the token

// Store tokens as { name -> hash }
let validTokens = {}; // Changed from Set to Object

// --- Helper Functions ---

function generateToken() {
    const randomBytes = crypto.randomBytes(Math.ceil(tokenLength * 3 / 4)); // Generate enough bytes
    const randomString = randomBytes.toString('base64url') // Use base64url for URL safety
                                    .replace(/=+$/, '') // Remove padding
                                    .slice(0, tokenLength); // Ensure exact length
    return tokenPrefix + randomString;
}

async function hashToken(token) {
    return await bcrypt.hash(token, saltRounds);
}

async function verifyToken(providedToken, storedHash) {
    if (!providedToken || !storedHash) {
        return false;
    }
    return await bcrypt.compare(providedToken, storedHash);
}

function loadTokens() {
    try {
        // Ensure the directory exists
        if (!fs.existsSync(internalTokensDirPath)) {
            console.log(`Creating token storage directory: ${internalTokensDirPath}`);
            fs.mkdirSync(internalTokensDirPath, { recursive: true });
        }

        // Check if the file exists
        if (fs.existsSync(internalTokensFilePath)) {
            const data = fs.readFileSync(internalTokensFilePath, 'utf8');
            const tokensObject = JSON.parse(data);
            // Basic validation: check if it's an object
            if (typeof tokensObject === 'object' && tokensObject !== null && !Array.isArray(tokensObject)) {
                validTokens = tokensObject;
                console.log(`Loaded ${Object.keys(validTokens).length} token hashes from ${internalTokensFilePath}`);
            } else {
                console.error(`Error: ${internalTokensFilePath} does not contain a valid JSON object. Initializing.`);
                validTokens = {};
                saveTokens(); // Overwrite/create with empty object
            }
        } else {
            console.log(`Token file not found at ${internalTokensFilePath}, creating a new one.`);
            validTokens = {};
            saveTokens(); // Create the file with an empty object
        }
    } catch (error) {
        console.error(`Error loading token hashes from ${internalTokensFilePath}:`, error);
        validTokens = {};
    }
}

function saveTokens() {
    try {
        // Ensure the directory exists before writing
        if (!fs.existsSync(internalTokensDirPath)) {
             fs.mkdirSync(internalTokensDirPath, { recursive: true });
        }
        fs.writeFileSync(internalTokensFilePath, JSON.stringify(validTokens, null, 2));
        console.log(`Saved ${Object.keys(validTokens).length} token hashes to ${internalTokensFilePath}`);
    } catch (error) {
        console.error(`Error saving token hashes to ${internalTokensFilePath}:`, error);
    }
}

// --- Middleware ---

// Middleware to check Admin Token for management endpoints
function checkAdminToken(req, res, next) {
    const authHeader = req.headers.authorization;
    if (!adminToken) {
        console.error("ADMIN_TOKEN is not set. Management endpoints are disabled.");
        return res.status(500).send('Server configuration error: Admin token not set.');
    }
    if (!authHeader || authHeader !== `Bearer ${adminToken}`) {
        return res.status(401).send('Unauthorized: Invalid or missing admin token.');
    }
    next();
}

// --- Routes ---

// Authentication endpoint used by Nginx auth_request
app.get('/auth', async (req, res) => {
    const authHeader = req.headers.authorization;
    console.log("Auth request received, Header:", authHeader ? authHeader.substring(0, 15) + '...' : 'None'); // Log prefix only

    if (!authHeader || !authHeader.startsWith('Bearer ')) {
        console.log("Auth failed: Missing or malformed Bearer token");
        return res.status(401).send('Unauthorized: Missing Bearer token.');
    }

    const providedToken = authHeader.split(' ')[1];
    let authenticatedUser = null;

    // Iterate through stored hashes and compare
    for (const name in validTokens) {
        const hash = validTokens[name];
        if (await verifyToken(providedToken, hash)) {
            authenticatedUser = name;
            break;
        }
    }

    if (authenticatedUser) {
        console.log(`Auth success: Valid token provided for user/service: ${authenticatedUser}`);
        // Send back the username in a header for Nginx to potentially log
        res.setHeader('X-Authenticated-User', authenticatedUser);
        res.status(200).send('OK');
    } else {
        console.log("Auth failed: Invalid token.");
        res.status(401).send('Unauthorized: Invalid token.');
    }
});

// Management endpoint: Add a new named token
app.post('/tokens', checkAdminToken, bodyParser.json(), async (req, res) => {
    const { name } = req.body;
    if (!name || typeof name !== 'string' || name.trim() === '') {
        return res.status(400).send('Bad Request: "name" field (non-empty string) is required for the token.');
    }

    if (validTokens.hasOwnProperty(name)) {
        return res.status(409).send(`Conflict: A token with the name '${name}' already exists.`);
    }

    const newToken = generateToken();
    try {
        const newHash = await hashToken(newToken);
        validTokens[name] = newHash;
        saveTokens();
        console.log(`Admin added token for: ${name}`);
        // Return the *generated* token only on creation
        res.status(201).send({ message: 'Token created successfully.', name: name, token: newToken });
    } catch (error) {
        console.error("Error hashing token:", error);
        res.status(500).send("Internal Server Error: Could not hash token.");
    }
});

// Management endpoint: List all token names (not the tokens/hashes themselves)
app.get('/tokens', checkAdminToken, (req, res) => {
    res.status(200).json(Object.keys(validTokens));
});

// Management endpoint: Delete a token by name
app.delete('/tokens/:name', checkAdminToken, (req, res) => {
    const nameToDelete = req.params.name;

    if (!validTokens.hasOwnProperty(nameToDelete)) {
        return res.status(404).send(`Not Found: Token with name '${nameToDelete}' does not exist.`);
    }

    delete validTokens[nameToDelete];
    saveTokens();
    console.log(`Admin deleted token for: ${nameToDelete}`);
    res.status(200).send({ message: 'Token deleted successfully.', name: nameToDelete });
});

// --- Initialization ---
loadTokens();

// Listen only on the loopback interface
const server = app.listen(port, '127.0.0.1', () => {
    console.log(`Auth service listening at http://127.0.0.1:${port}`);
    if (!adminToken) {
        console.warn("Warning: ADMIN_TOKEN environment variable is not set. Token management endpoints will not work.");
    } else {
        console.log("Admin token is set. Management endpoints are active.");
    }
    console.log(`Using tokens file: ${internalTokensFilePath}`);
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('SIGTERM signal received: closing HTTP server');
    server.close(() => {
        console.log('HTTP server closed');
        process.exit(0);
    });
}); 