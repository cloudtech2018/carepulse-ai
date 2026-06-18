# CarePulse AI App

SwiftUI iOS app inspired by the attached CarePulse AI mockup.

## Open in Xcode

Open:

`CarePulseAIApp.xcodeproj`

Then choose an iPhone simulator and press Run.

## Backend

### Local backend

Start the local backend from the project folder:

```sh
./start_backend.sh
```

The script prints the exact iPhone URL to test. On the Mac simulator, the backend also runs on:

`http://localhost:8765`

For a real iPhone, use your Mac's Wi-Fi IP address in the app's Backend URL field, for example:

`http://192.168.1.25:8765`

Do not use `localhost` on a real iPhone. On the phone, `localhost` points back to the phone, not to your Mac.

If the iPhone cannot connect:

- Make sure the iPhone and Mac are on the same Wi-Fi network.
- Start the backend with `./start_backend.sh` and keep that terminal open.
- Open `http://YOUR-MAC-IP:8765/health` from Safari on the iPhone.
- Allow CarePulse AI to access the local network when iOS asks.
- If macOS Firewall is on, allow incoming connections for Python.
- If you are on guest, school, office, or hotspot Wi-Fi, try a normal private home Wi-Fi because some networks block phone-to-computer connections.

### Remote backend

For a real iPhone outside your Mac's Wi-Fi network, deploy the backend to a public HTTPS host and put that URL in the app's Backend URL field.

This project includes a `Procfile`, so Python-friendly hosts such as Render, Railway, Fly.io, or Heroku-style platforms can run:

```sh
python3 backend/server.py
```

The server reads the host platform's `PORT` environment variable automatically.

For Render:

1. Push this project to a GitHub repository, excluding files covered by `.gitignore`.
2. In Render, choose New > Blueprint and select the repository.
3. Render will read `render.yaml` and start the web service.
4. Open the Render service URL plus `/health`.

After deployment, test:

`https://YOUR-SERVER-DOMAIN/health`

Then set the app Backend URL to:

`https://YOUR-SERVER-DOMAIN`

Do not include `/health` in the app field.

Optional environment variable:

- `CAREPULSE_DATA_PATH`: where the JSON data file should be stored on the server. If the host has ephemeral storage, use a persistent disk or database before relying on it for production records.

The backend provides authentication and records real accelerometer/SVM sensor windows to:

`backend/data/carepulse.json`

Useful backend endpoints:

- `GET /health`
- `POST /auth/register`
- `POST /auth/login`
- `POST /auth/logout`
- `GET /auth/me`
- `POST /sensor-records`
- `GET /sensor-records?limit=100`
- `GET /sensor-summary`

## Screens Included

- Onboarding / sign-in screen
- Dashboard with activity ring and status cards
- Activity trends with weekly chart
- Health metrics and recommendations
- Alerts and notifications
- Profile / feature summary
