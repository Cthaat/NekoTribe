export function withJsonAccept(
  headers: Readonly<Record<string, string>> = {}
): Record<string, string> {
  const result = { ...headers };
  if (
    !Object.keys(result).some(
      key => key.toLowerCase() === 'accept'
    )
  ) {
    result.Accept = 'application/json';
  }
  return result;
}
