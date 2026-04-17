using System.Security.Cryptography;

if (args.Length == 0)
{
    return ShowUsage();
}

return args[0].ToLowerInvariant() switch
{
    "sign" => Sign(args[1..]),
    "keygen" => GenerateKeyPair(args[1..]),
    _ => ShowUsage(),
};

static int Sign(string[] args)
{
    string? inputPath = null;
    string? keyPath = null;
    string? outputPath = null;

    for (var i = 0; i < args.Length; i += 2)
    {
        if (i + 1 >= args.Length)
        {
            Console.Error.WriteLine($"Missing value for argument: {args[i]}");
            return 2;
        }

        switch (args[i])
        {
            case "--input":
                inputPath = args[i + 1];
                break;
            case "--key":
                keyPath = args[i + 1];
                break;
            case "--output":
                outputPath = args[i + 1];
                break;
            default:
                Console.Error.WriteLine($"Unknown argument: {args[i]}");
                return 2;
        }
    }

    if (string.IsNullOrWhiteSpace(inputPath) || string.IsNullOrWhiteSpace(keyPath) || string.IsNullOrWhiteSpace(outputPath))
    {
        Console.Error.WriteLine("The --input, --key, and --output arguments are required.");
        return 2;
    }

    if (!File.Exists(inputPath))
    {
        Console.Error.WriteLine($"Input file not found: {inputPath}");
        return 2;
    }

    if (!File.Exists(keyPath))
    {
        Console.Error.WriteLine($"Private key not found: {keyPath}");
        return 2;
    }

    var pem = File.ReadAllText(keyPath);
    using var rsa = RSA.Create();
    rsa.ImportFromPem(pem);

    byte[] signature;
    using (var stream = File.OpenRead(inputPath))
    {
        signature = rsa.SignData(stream, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }

    var outputDir = Path.GetDirectoryName(Path.GetFullPath(outputPath));
    if (!string.IsNullOrWhiteSpace(outputDir))
    {
        Directory.CreateDirectory(outputDir);
    }

    File.WriteAllBytes(outputPath, signature);
    return 0;
}

static int GenerateKeyPair(string[] args)
{
    string? privateKeyPath = null;
    string? publicKeyPath = null;
    var force = false;

    for (var i = 0; i < args.Length; i++)
    {
        switch (args[i])
        {
            case "--private":
                if (++i >= args.Length)
                {
                    Console.Error.WriteLine("Missing value for argument: --private");
                    return 2;
                }
                privateKeyPath = args[i];
                break;
            case "--public":
                if (++i >= args.Length)
                {
                    Console.Error.WriteLine("Missing value for argument: --public");
                    return 2;
                }
                publicKeyPath = args[i];
                break;
            case "--force":
                force = true;
                break;
            default:
                Console.Error.WriteLine($"Unknown argument: {args[i]}");
                return 2;
        }
    }

    if (string.IsNullOrWhiteSpace(privateKeyPath) || string.IsNullOrWhiteSpace(publicKeyPath))
    {
        Console.Error.WriteLine("The --private and --public arguments are required.");
        return 2;
    }

    foreach (var path in new[] { privateKeyPath, publicKeyPath })
    {
        if (File.Exists(path) && !force)
        {
            Console.Error.WriteLine($"Refusing to overwrite existing key: {path}");
            return 2;
        }

        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }

    using var rsa = RSA.Create(4096);
    File.WriteAllText(privateKeyPath, rsa.ExportRSAPrivateKeyPem());
    File.WriteAllText(publicKeyPath, rsa.ExportSubjectPublicKeyInfoPem());

    Console.WriteLine($"Wrote private key to {privateKeyPath}");
    Console.WriteLine($"Wrote public key to {publicKeyPath}");
    return 0;
}

static int ShowUsage()
{
    Console.Error.WriteLine("Usage:");
    Console.Error.WriteLine("  MonitorSMSSigner sign --input <file> --key <private-pem> --output <signature>");
    Console.Error.WriteLine("  MonitorSMSSigner keygen --private <private-pem> --public <public-pem> [--force]");
    return 2;
}
