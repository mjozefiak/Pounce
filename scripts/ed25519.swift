// Ed25519 helper for the release scripts (run with `swift scripts/ed25519.swift ...`; no build, no package).
//
//   verify <public-key-base64> <file> <signature-base64>   exit 0 when the signature is valid, 1 when not, 64 on usage
//   public-key                                              reads a base64 32-byte private seed from stdin and prints
//                                                           the public key (used by the script tests only)
//
// `sign_update --verify` takes the public key from the PRIVATE key it is given, so it cannot check a signature
// against the key committed in Info.plist. This can: `scripts/sparkle-sign.sh check-key` uses `verify` for that.
// Nothing here prints key material other than the public key.
import CryptoKit
import Foundation

func fail(_ code: Int32, _ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(code)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "verify":
  guard args.count == 4,
    let key = Data(base64Encoded: String(args[args.startIndex + 1])),
    let signature = Data(base64Encoded: String(args[args.startIndex + 3])),
    let file = FileManager.default.contents(atPath: String(args[args.startIndex + 2]))
  else { fail(64, "usage: verify <public-key-base64> <file> <signature-base64>") }
  guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else {
    fail(1, "The public key is not a valid Ed25519 key.")
  }
  exit(publicKey.isValidSignature(signature, for: file) ? 0 : 1)
case "public-key":
  let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let seed = Data(base64Encoded: input),
    let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  else { fail(1, "The private key is not valid.") }
  print(key.publicKey.rawRepresentation.base64EncodedString())
default:
  fail(64, "usage: ed25519.swift verify <public-key-base64> <file> <signature-base64> | public-key")
}
