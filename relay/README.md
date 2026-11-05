# RoosterChat push relay

Lets iOS show "New Message" when the app is suspended. It stores no messages: it receives
a device token and asks Apple to show a fixed alert. Apple never gets message text. The
relay can see the sender and text only if your XMPP server is configured to include them in
push notifications, so check that setting if whoever runs the relay isn't trusted.
It uses [fpush](https://github.com/monal-im/fpush) with a small Prosody for federation.

## 1. Apple setup (developer account owner)

In [Identifiers](https://developer.apple.com/account/resources/identifiers/list), open
`io.github.lazy.roostchat`:

1. Enable **Push Notifications**, and save.
2. Under Push Notifications, click **Configure**, then create a **Production SSL
   Certificate** using a signing request (below). Download `aps.cer`.

Then, in [Profiles](https://developer.apple.com/account/resources/profiles/list), edit the
App Store profile, regenerate it, and download it. It must be regenerated, because the
existing one doesn't include push.

The signing request and private key can stay with whoever runs the relay:

```sh
openssl genrsa -out apns.key 2048
openssl req -new -key apns.key -out apns.csr -subj "/CN=RoosterChat APNs"
# After receiving aps.cer:
openssl x509 -inform DER -in aps.cer -out aps.pem
openssl pkcs12 -export -inkey apns.key -in aps.pem -out apns.p12
```

Don't use `-legacy` here: unlike the signing certificate, fpush wants the modern format.

Update the app's signing profile secret:

```sh
base64 -w0 profile.mobileprovision | gh secret set PROVISIONING_PROFILE -R 0xlazY/RoostChat
```

## 2. DNS and firewall

- Point an `A` or `AAAA` record for your push domain at the VPS.
- Open TCP port **5269** to the internet. Port 5347 stays private to Docker.

nginx isn't involved, because 5269 is raw XMPP rather than HTTP. Make sure nothing else on
the VPS already uses port 5269.

## 3. Install

```sh
cd relay
./setup.sh
cp apns.p12 secrets/apns.p12
sudo chown 65532 settings.json secrets/apns.p12   # the user fpush runs as
sudo chmod 600 settings.json secrets/apns.p12
sudo certbot certonly --nginx -d push.example.com   # your existing nginx can do this
sudo ./copy-cert.sh                                 # also copies on later renewals
docker compose up -d --build
docker compose logs -f
```

The first build compiles fpush and can take several minutes. If fpush reports that it can't
read its settings or certificate, run `docker compose run --rm --entrypoint id fpush` if the
image allows it, or check the image's user, and adjust the `chown` above to match.

Add this so that renewals reach Prosody:

```sh
sudo certbot reconfigure --cert-name push.example.com --deploy-hook "$PWD/copy-cert.sh"
```

## 4. Connect the app

In RoosterChat, open **Settings > Push Relay**, enter your push domain, and save. The account
screen's diagnostics then show the push status.

## Checking it

- `docker compose logs fpush` should show the component connecting.
- Your XMPP server must be able to federate with the push domain. If it only allows approved
  servers, ask its administrator to allow this domain.

## Security

- `secrets/`, `certs/`, `.env` and `settings.json` hold credentials and are ignored by git.
- The APNs certificate can only send pushes to this app. Revoke it in the developer account
  if it leaks. It expires after about a year.
- A device token alone lets someone who controls an XMPP server wake that device, with the
  20 second rate limit. It doesn't reveal message contents by itself.
