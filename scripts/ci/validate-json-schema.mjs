// Validates one JSON file against one draft-07 JSON schema with ajv 8 from the root devDependencies, and prints every error.
//   usage: node validate-json-schema.mjs <schema-file> <data-file>
// Exit status: 0 valid, 1 invalid or unreadable file, 2 wrong arguments.
import Ajv from "ajv";
import { readFileSync } from "node:fs";

const [schemaFile, dataFile] = process.argv.slice(2);
if (!schemaFile || !dataFile) { console.error("usage: validate-json-schema.mjs <schema-file> <data-file>"); process.exit(2); }
let validate, data;
try {
  validate = new Ajv({ allErrors: true }).compile(JSON.parse(readFileSync(schemaFile, "utf8")));
  data = JSON.parse(readFileSync(dataFile, "utf8"));
} catch (e) {
  console.log(`${dataFile} invalid`); console.log(e.message); process.exit(1);
}
if (validate(data)) { console.log(`${dataFile} valid`); process.exit(0); }
console.log(`${dataFile} invalid`); console.log(JSON.stringify(validate.errors, null, 2)); process.exit(1);
