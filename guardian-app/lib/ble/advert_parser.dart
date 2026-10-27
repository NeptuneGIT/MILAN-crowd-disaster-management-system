/// Manufacturer data bytes for company 0xFFFF as delivered by flutter_blue_plus
/// (company ID already stripped): [0x52, 0x55, 0x02, eid0..eid7].
/// Contract: README §3.2. The 8 bytes are a rotating encrypted ID (EID). The phone cannot
/// decrypt it; it only compares it with the EIDs the server says currently mean a missing dependent.
const int kCompanyId = 0xFFFF;
const List<int> kMagic = [0x52, 0x55];
const int kFormatEid = 0x02;

/// Returns the EID as 16 lowercase hex characters, or null if the payload is not one of our v2 beacons.
String? parseEid(List<int> msd) {
  if (msd.length < 11) return null;
  if (msd[0] != kMagic[0] || msd[1] != kMagic[1]) return null;
  if (msd[2] != kFormatEid) return null;
  return msd.sublist(3, 11).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
