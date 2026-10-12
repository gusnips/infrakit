import js from "@eslint/js";
import ts from "typescript-eslint";

export default ts.config(
  { ignores: ["dist/**", "node_modules/**", ".scratch/**"] },
  js.configs.recommended,
  ...ts.configs.strict,
  {
    files: ["**/*.ts"],
    rules: { "@typescript-eslint/no-explicit-any": "error" },
  },
);
