# SIS.EHIRSHMAN — AWS Migration

**מטרה:** ניתוק מ-Base44 והעברה ל-AWS עצמאי (React + Node.js + PostgreSQL).

```
sis-aws/
├── source/           ← הקוד המקורי (reference, modified by Codex)
├── backend/          ← השרת החדש (Node.js + Express + Playwright)
├── db/               ← schema.sql + migrations
├── infra/            ← AWS deploy configs (EC2 user-data, systemd, ...)
├── docs/             ← תכנון, סטטוס, מסמך פונקציות
└── docker-compose.yml← הרצה מקומית
```

## מה הושלם

✅ **DB Schema** (`db/schema.sql`) — JSONB-first design  
✅ **Backend skeleton** (`backend/src/`):
- Express + Helmet + Compression + Pino logging
- PG pool + transactions
- JWT auth + session table + token revocation
- Generic entity CRUD: `/api/entities/:type` (replaces `base44.entities.*`)
- Audit log
- Integrations: Twilio, SendGrid, OpenAI, Linet, S3, Playwright PDF, Roboflow

✅ **~85 פונקציות פורטו** — `backend/src/functions/`:
- מסלולי הצעות מחיר ציבוריים + טפסים + חתימות + הזמנות רכש
- Linet (חשבוניות, קבלות, חשבונית-קבלה, הצעה, חשבונית זיכוי, סנכרון לקוחות/פריטים, דוח חשבון)
- Field worker / role-based secureEntityAccess
- אימייל (SendGrid + automated + custom + webhook + שלוחות Gmail)
- בוטים (publicBotChat, getPublicBot, customerBotInquiry, invokeChatBot, triggerBotNotification)
- AI (classifyIncomeItems, scanExpenseDocument, translateInventoryText, translateQuoteItems, predictiveInsights)
- Blueprint AI (analyzeBlueprintAI, roboflowBlueprint, testApifyBlueprint)
- Agents (createAgentConversation, getAgentConfig, getAgentConversation, getAgentConversations, sendAgentMessage)
- WhatsApp / Twilio webhooks, attendance, biometrics, OTP
- כלי ניהול (migrateLegacyCategories, syncOwnerWithdrawals, syncInventoryFromHistory, generateTransactionReferences, processDynamicFields, convertPdfToImage)

✅ **Frontend SDK shim** (`source/src/api/base44Client.js.NEW`) — drop-in replacement.

✅ **Docker Compose** — `docker-compose up` מקים PG + backend מקומית.

✅ **CSV import scripts** — `scripts/import-csv.js`, `import-internal-auth.js`, `import-all.sh`.

✅ **AWS infra** (`infra/`) — `ec2-userdata.sh`, `sis-backend.service`, `infra/README.md`.

## מה נשאר

🟡 **פונקציות אופציונליות / חיצוניות** מסומנות כ-stubs ומחזירות 501:
- `analyzeLocalBlueprint` (דרש שרת ngrok חיצוני — בוטל לטובת LLM vision)
- `exportLeadsToCRM` (Salesforce/HubSpot OAuth)
- `syncLeadToGoogleCalendar`, `syncLeadToGoogleContacts` (Google OAuth)
- `sendGmailEmail`, `receiveGmailEmails` (משתמשים ב-SendGrid במקום)

⬜ **Frontend cutover** — להחליף `base44Client.js` ב-`.NEW` (פעולה של שורה אחת):
```bash
mv source/src/api/base44Client.js{,.OLD}
mv source/src/api/base44Client.js.NEW source/src/api/base44Client.js
```

⬜ **Phase 4: Data migration** — מחכה לייצוא CSV מ-Base44.  
⬜ **Phase 5: AWS deploy** — מחכה לחשבון AWS.

## הרצה מקומית

```bash
cd backend && cp .env.example .env  # ערוך את הסודות לפי הצורך
cd .. && docker-compose up --build
```
ה-API יהיה זמין ב-`http://localhost:3001`. בדיקת בריאות:
```bash
curl http://localhost:3001/health
```

ייצור משתמש admin (הרצה ידנית בפעם הראשונה):
```bash
docker-compose exec backend node -e "
import('./src/auth/password.js').then(async ({ hashPassword }) => {
  console.log(await hashPassword('YOUR_PASSWORD'));
});"
# העתק את ה-hash, ואז:
docker-compose exec postgres psql -U sis -d sis -c \\
  \"INSERT INTO internal_auth (email, full_name, password_hash, password_salt, role)
    VALUES ('admin@example.com', 'Admin', '<HASH>', '', 'admin');\"
```

## טסט מהיר של ה-API
```bash
# Login
TOKEN=$(curl -s http://localhost:3001/api/auth/login \\
  -H 'Content-Type: application/json' \\
  -d '{"email":"admin@example.com","password":"YOUR_PASSWORD"}' \\
  | jq -r .token)

# Create an entity
curl -s -X POST http://localhost:3001/api/entities/Contact \\
  -H "Authorization: Bearer $TOKEN" \\
  -H 'Content-Type: application/json' \\
  -d '{"name":"Test Contact","phone":"+972501234567"}'

# List
curl -s -X POST http://localhost:3001/api/entities/Contact/list \\
  -H "Authorization: Bearer $TOKEN" \\
  -H 'Content-Type: application/json' \\
  -d '{"filter":{},"sort":"-created_at","limit":10}'
```

## ייבוא נתונים מ-Base44

1. ב-Base44 → ייצוא CSV לכל entity. שמור תחת `backend/exports/`:
   ```
   backend/exports/
     Income.csv
     Expense.csv
     Contact.csv
     ...
     InternalAuth.csv
   ```
2. הרץ:
   ```bash
   cd backend && bash scripts/import-all.sh ./exports
   ```

## Deploy ל-AWS
ראה `infra/README.md`.

---

## הערה לגבי שינויים מקבילים

GPT Codex עובד במקביל על `source/`. כשצריך לעשות sync:
1. בצע `git pull` ב-`source/`.
2. וודא ש-`source/src/api/base44Client.js` עדיין מצביע על ה-shim שלנו (לא חזר ל-SDK המקורי).
3. אם הוא הוסיף שדות חדשים ל-entities — אין צורך לשנות סכמה (JSONB גמיש).
4. אם הוסיף פונקציות חדשות — הוסף ל-`backend/src/functions/index.js` ו-`docs/REMAINING_FUNCTIONS.md`.
