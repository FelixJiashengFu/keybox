namespace KeyBox.Core;

/// <summary>Ready-to-paste lines that set an environment variable to a key.</summary>
public static class Snippets
{
    public static string PowerShell(string name, string value) => $"$env:{name} = '{value.Replace("'", "''")}'";

    public static string Bash(string name, string value) => $"export {name}='{value.Replace("'", "'\\''")}'";

    public static string Cmd(string name, string value) => $"set \"{name}={value}\"";

    public static string DotEnv(string name, string value) =>
        value.IndexOfAny([' ', '#', '"', '\'', '=', '\\']) >= 0
            ? $"{name}=\"{value.Replace("\\", "\\\\").Replace("\"", "\\\"")}\""
            : $"{name}={value}";

    public static bool IsValidName(string name) =>
        name.Length > 0 && (char.IsAsciiLetter(name[0]) || name[0] == '_') && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '_');
}
