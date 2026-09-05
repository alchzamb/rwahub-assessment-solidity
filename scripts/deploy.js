async function main() {
  const Token = await artifacts.require("Token");
  const token = await Token.new();
  console.log("Token deployed to:", token.address);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
