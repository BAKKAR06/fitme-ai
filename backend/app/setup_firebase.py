"""Connects this laptop's FitMe to your Firebase project (used by SETUP_FIREBASE.bat).

    python -m app.setup_firebase WEB_API_KEY

Needs backend/data/firebase-service-account.json (Firebase console -> Project settings ->
Service accounts -> Generate new private key). Writes backend/data/firebase_web.json and
lib/firebase_options.dart (the app's public Firebase keys), then checks that
Firestore and e-mail/password sign-in work.
"""
import json
import sys
import time
from pathlib import Path

import httpx

BACKEND = Path(__file__).resolve().parent.parent
DATA = BACKEND / "data"
APP_OPTIONS = BACKEND.parent / "lib" / "firebase_options.dart"


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("usage: setup_firebase.py WEB_API_KEY")
        return 2
    api_key = sys.argv[1].strip()
    key_file = DATA / "firebase-service-account.json"
    if not key_file.exists():
        print(f"ERROR: put the service-account key here first: {key_file}")
        return 1
    project_id = json.loads(key_file.read_text(encoding="utf-8")).get("project_id", "")
    print("Project:", project_id)

    (DATA / "firebase_web.json").write_text(json.dumps({"apiKey": api_key, "projectId": project_id}, indent=1),
                                            encoding="utf-8")
    APP_OPTIONS.write_text(
        "// Written by SETUP_FIREBASE.bat. Public Firebase keys of the app (not secrets).\n"
        f"const kFirebaseApiKey = '{api_key}';\n"
        f"const kFirebaseProjectId = '{project_id}';\n",
        encoding="utf-8",
    )
    print("Saved the app keys:", APP_OPTIONS)

    ok = True
    # 1) Firestore through the service account
    try:
        from app import store

        st = store.FirestoreStore(DATA)
        st.update_config({"setup_checked_at": time.time()})
        print("OK  Firestore: config/app written, owner:", st.get_config().get("owner_uid") or "(first account will be)")
    except Exception as exc:
        ok = False
        print("ERROR Firestore:", type(exc).__name__, str(exc)[:300])
        print("      Is Firestore created (Build -> Firestore Database -> Create database)?")
    # 2) e-mail/password sign-in is switched on and the web key belongs to the project
    try:
        r = httpx.post(f"https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key={api_key}",
                       json={"email": "setup-check@fitme.invalid", "password": "x-check-1", "returnSecureToken": True},
                       timeout=20)
        message = (r.json().get("error") or {}).get("message", "")
        if "OPERATION_NOT_ALLOWED" in message:
            ok = False
            print("ERROR Authentication: turn on Email/Password (Build -> Authentication -> Sign-in method)")
        elif "API_KEY" in message or "API key" in message:
            ok = False
            print("ERROR the Web API key is wrong:", message)
        else:
            print("OK  Authentication: e-mail/password sign-in is on")
    except Exception as exc:
        ok = False
        print("ERROR Authentication check:", type(exc).__name__, exc)

    print()
    print("READY. Now run BUILD_APK_ONLY.bat (the app gets the keys) and START_LOCAL_GPU.bat." if ok
          else "Fix the errors above and run SETUP_FIREBASE.bat again.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
