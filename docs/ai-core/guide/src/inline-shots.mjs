// Reads HTML on stdin and replaces every <img src="shot:NAME" width=".." height=".."> with the
// embedded WebP from shots/NAME.webp (a data: URI) and its true pixel size. Fails on a missing shot.
import fs from "node:fs";
const dir = new URL(".", import.meta.url).pathname;
const html = fs.readFileSync(0, "utf8");
function size(buf) {
  const kind = buf.toString("ascii", 12, 16);
  if (kind === "VP8 ") return [buf.readUInt16LE(26) & 0x3fff, buf.readUInt16LE(28) & 0x3fff];
  if (kind === "VP8L") { const b = buf.readUInt32LE(21); return [(b & 0x3fff) + 1, ((b >> 14) & 0x3fff) + 1]; }
  if (kind === "VP8X") return [buf.readUIntLE(24, 3) + 1, buf.readUIntLE(27, 3) + 1];
  throw new Error("unknown WebP chunk " + kind);
}
const out = html.replace(/src="shot:([a-z0-9-]+)"([^>]*?) width="\d+" height="\d+"/g, (_m, name, mid) => {
  const buf = fs.readFileSync(dir + "shots/" + name + ".webp");
  const [w, h] = size(buf);
  return 'src="data:image/webp;base64,' + buf.toString("base64") + '"' + mid + ' width="' + w + '" height="' + h + '"';
});
if (/shot:/.test(out.replace(/<script[\s\S]*?<\/script>/g, ""))) throw new Error("an image placeholder was not replaced");
process.stdout.write(out);
