// ESP32-C3 lost-child beacon. Advert format: SPEC §3.2 (shared contract with the Flutter app).
// Rotating encrypted ID: every 10 minutes the band advertises a new 8-byte EID and a new random BLE address,
//   EID = first 8 bytes of AES-128(key, block),  block = 12 zero bytes + (unix time / 600) as 4 big-endian bytes
// Only the database holds a copy of the key, so only it can tell which child an EID belongs to.
#include <Arduino.h>
#include <Preferences.h>
#include <NimBLEDevice.h>
#include "mbedtls/aes.h"

static constexpr uint16_t COMPANY_ID = 0xFFFF;
static constexpr uint8_t  MAGIC0 = 0x52, MAGIC1 = 0x55, FORMAT_EID = 0x02;
static constexpr uint16_t ADV_MIN = 160, ADV_MAX = 240;   // 0.625 ms units -> 100..150 ms
static constexpr uint32_t EPOCH_S = 600;                  // must match band_epoch() in supabase/schema.sql

Preferences prefs;
uint32_t beaconId = 0;          // the printed label (KM-000123) only; it is never broadcast
uint8_t  key[16];
bool     hasKey = false;
uint32_t unixNow = 0;           // 0 = clock never set. Counted up once a second from millis().
uint32_t lastTickMs = 0;
uint32_t advertisedEpoch = 0;   // 0 = not advertising yet
int8_t   txDbm = 9;
String   line;

// First 8 bytes of AES-128(key, epoch block). Same as band_eid() in SQL.
void computeEid(uint32_t epoch, uint8_t out8[8]) {
  uint8_t in[16] = {0}, out[16];
  in[12] = epoch >> 24; in[13] = epoch >> 16; in[14] = epoch >> 8; in[15] = epoch;
  mbedtls_aes_context ctx;
  mbedtls_aes_init(&ctx);
  mbedtls_aes_setkey_enc(&ctx, key, 128);
  mbedtls_aes_crypt_ecb(&ctx, MBEDTLS_AES_ENCRYPT, in, out);
  mbedtls_aes_free(&ctx);
  memcpy(out8, out, 8);
}

String hex(const uint8_t* b, size_t n) {
  String s;
  for (size_t i = 0; i < n; i++) { char t[3]; snprintf(t, sizeof t, "%02x", b[i]); s += t; }
  return s;
}

bool parseHex(const String& s, uint8_t* out, size_t n) {   // exactly 2*n hex characters
  if (s.length() != 2 * n) return false;
  for (size_t i = 0; i < n; i++) {
    char t[3] = { s[2 * i], s[2 * i + 1], 0 }, *end;
    out[i] = (uint8_t)strtoul(t, &end, 16);
    if (*end) return false;
  }
  return true;
}

bool provisioned() { return beaconId && hasKey && unixNow; }

void startAdvertising() {
  uint32_t epoch = unixNow / EPOCH_S;
  uint8_t msd[2 + 2 + 1 + 8];                       // company(2) magic(2) ver(1) eid(8)
  msd[0] = COMPANY_ID & 0xFF; msd[1] = COMPANY_ID >> 8;
  msd[2] = MAGIC0; msd[3] = MAGIC1; msd[4] = FORMAT_EID;
  computeEid(epoch, &msd[5]);

  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->stop();

  // A fresh random non-resolvable address with every ID, so the MAC cannot be used to follow the band.
  // (uncompiled: check these two NimBLE calls against the installed library version)
  uint8_t a[6];
  for (auto& b : a) b = esp_random() & 0xFF;
  a[5] &= 0x3F;                                     // top two bits 00 = non-resolvable private address
  NimBLEDevice::setOwnAddrType(BLE_OWN_ADDR_RANDOM);
  if (!NimBLEDevice::setOwnAddr(NimBLEAddress(a, BLE_ADDR_RANDOM))) Serial.println("WARN could not set random address");

  NimBLEAdvertisementData ad;
  ad.setFlags(0x06);
  ad.setManufacturerData(msd, sizeof(msd));
  adv->setAdvertisementData(ad);
  adv->enableScanResponse(false);
  adv->setConnectableMode(BLE_GAP_CONN_MODE_NON);
  adv->setMinInterval(ADV_MIN);
  adv->setMaxInterval(ADV_MAX);
  adv->start();
  advertisedEpoch = epoch;
}

void printLabel() { Serial.printf("KM-%06lu", (unsigned long)beaconId); }

void printMissing() {
  Serial.print("UNPROVISIONED - missing:");
  if (!beaconId) Serial.print(" ID <n>");
  if (!hasKey)   Serial.print(" KEY <32 hex>");
  if (!unixNow)  Serial.print(" TIME <unix seconds>");
  Serial.println();
}

// Start (or stop) advertising once everything is set; called after every provisioning command.
void refresh() {
  if (provisioned()) startAdvertising();
  else { NimBLEDevice::getAdvertising()->stop(); advertisedEpoch = 0; }
}

void handle(String cmd) {
  cmd.trim();
  if (cmd.startsWith("ID ")) {
    long n = cmd.substring(3).toInt();               // toInt() returns 0 on garbage
    if (n < 1 || n > 2147483647L) { Serial.println("ERR id must be 1..2147483647"); return; }
    beaconId = (uint32_t)n;
    prefs.putUInt("id", beaconId);
    refresh();
    Serial.printf("OK id=%lu label=", (unsigned long)beaconId); printLabel(); Serial.println();
  } else if (cmd.startsWith("KEY ")) {
    String h = cmd.substring(4); h.trim();
    uint8_t k[16];
    if (!parseHex(h, k, 16)) { Serial.println("ERR key must be 32 hex characters"); return; }
    memcpy(key, k, 16); hasKey = true;
    prefs.putBytes("key", key, 16);
    refresh();
    Serial.println("OK key set");                    // never echoed back
  } else if (cmd.startsWith("TIME ")) {
    long long t = cmd.substring(5).toInt();
    if (t < 1700000000LL || t > 4000000000LL) { Serial.println("ERR time must be unix seconds"); return; }
    unixNow = (uint32_t)t; lastTickMs = millis();
    prefs.putUInt("t", unixNow);
    refresh();
    Serial.printf("OK time=%lu epoch=%lu\n", (unsigned long)unixNow, (unsigned long)(unixNow / EPOCH_S));
  } else if (cmd == "INFO") {
    Serial.printf("id=%lu label=", (unsigned long)beaconId); printLabel();
    Serial.printf(" key=%s time=%lu epoch=%lu", hasKey ? "set" : "MISSING", (unsigned long)unixNow, (unsigned long)(unixNow / EPOCH_S));
    if (hasKey && unixNow) { uint8_t e[8]; computeEid(unixNow / EPOCH_S, e); Serial.printf(" eid=%s", hex(e, 8).c_str()); }
    Serial.printf(" tx=%ddBm interval=%u-%ums advertising=%s uptime=%lus\n",
                  txDbm, ADV_MIN * 5 / 8, ADV_MAX * 5 / 8,
                  NimBLEDevice::getAdvertising()->isAdvertising() ? "yes" : "no",
                  millis() / 1000);
  } else if (cmd.startsWith("TX ")) {
    long dbm = cmd.substring(3).toInt();
    if (dbm < -12 || dbm > 9) { Serial.println("ERR tx must be -12..9"); return; }
    txDbm = (int8_t)dbm;
    prefs.putChar("tx", txDbm);
    NimBLEDevice::setPower(txDbm);
    Serial.printf("OK tx=%d\n", txDbm);
  } else if (cmd == "WIPE") {
    prefs.clear();
    beaconId = 0; hasKey = false; unixNow = 0; txDbm = 9;
    memset(key, 0, sizeof key);
    refresh();
    NimBLEDevice::setPower(txDbm);
    Serial.println("OK wiped");
  } else if (cmd.length()) {
    Serial.println("ERR commands: ID <n> | KEY <32 hex> | TIME <unix> | INFO | TX <dbm> | WIPE");
  }
}

void setup() {
  Serial.begin(115200);
  prefs.begin("beacon", false);
  beaconId = prefs.getUInt("id", 0);
  txDbm    = prefs.getChar("tx", 9);
  hasKey   = prefs.getBytes("key", key, 16) == 16;
  unixNow  = prefs.getUInt("t", 0);                  // last saved time; stale by however long it was off
  lastTickMs = millis();
  NimBLEDevice::init("");
  NimBLEDevice::setPower(txDbm);
  refresh();
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') { handle(line); line = ""; }
    else if (line.length() < 64) line += c;
  }

  while (millis() - lastTickMs >= 1000) { lastTickMs += 1000; if (unixNow) unixNow++; }

  // New 10-minute slot: new EID and new address. Save the clock so a power cut resumes close to the real time.
  if (provisioned() && unixNow / EPOCH_S != advertisedEpoch) {
    prefs.putUInt("t", unixNow);
    startAdvertising();
  }

  static uint32_t lastHint = 0;
  if (!provisioned() && millis() - lastHint >= 2000) {
    lastHint = millis();
    printMissing();
  }
}
