using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using SoulspireLauncher.Models;

namespace SoulspireLauncher.Services;

public sealed record PackageVerificationResult(
    bool IsValid,
    string ComputedSha256,
    long SizeBytes,
    string ErrorMessage)
{
    public static PackageVerificationResult Ok(string sha256, long sizeBytes) =>
        new(true, sha256, sizeBytes, string.Empty);

    public static PackageVerificationResult Fail(string error, string sha256 = "", long sizeBytes = 0) =>
        new(false, sha256, sizeBytes, error);
}

public sealed record ExtractedUpdatePackage(
    bool Success,
    string ExtractedExePath,
    string ExtractedExeSha256,
    string? ExtractedUpdaterPath,
    string? ExtractedUpdaterSha256,
    string ErrorMessage);

/// <summary>
/// Cryptographic integrity, origin, and signature verifier for SoulspireXI launcher updates.
/// Fails closed on any hash mismatch, untrusted origin, path traversal, or invalid signature.
/// </summary>
public static class LauncherPackageVerifier
{
    public const string SupportedSignatureAlgorithm = "ECDSA-P256-SHA256";
    public const string TrustedSigningKeyId = "soulspire-launcher-release-v1";
    public const string EmbeddedPublicKeyResourceName = "SoulspireLauncher.Resources.release-signing-public.pem";
    public const long DefaultMinimumValidExeBytes = 512 * 1024;

    public static string? LoadEmbeddedTrustedPublicKeyPem()
    {
        var assembly = typeof(LauncherPackageVerifier).Assembly;
        using var stream = assembly.GetManifestResourceStream(EmbeddedPublicKeyResourceName);
        if (stream is null)
        {
            return null;
        }

        using var reader = new StreamReader(stream, Encoding.UTF8);
        var pem = reader.ReadToEnd().Trim();
        return string.IsNullOrWhiteSpace(pem) ? null : pem;
    }

    public static string ComputeSha256Hex(string filePath)
    {
        using var stream = File.OpenRead(filePath);
        var hash = SHA256.HashData(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public static bool IsValidSha256Hex(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var trimmed = value.Trim();
        if (trimmed.Length != 64)
        {
            return false;
        }

        foreach (var ch in trimmed)
        {
            var isHex = (ch is >= '0' and <= '9') ||
                        (ch is >= 'a' and <= 'f') ||
                        (ch is >= 'A' and <= 'F');
            if (!isHex)
            {
                return false;
            }
        }

        return true;
    }

    public static bool IsTrustedDownloadUri(
        string? url,
        string expectedOwner = "Infomatictek",
        string expectedRepo = "soulspirexi-launcher",
        bool allowLoopbackHttpForTests = false)
    {
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri))
        {
            return false;
        }

        if (allowLoopbackHttpForTests &&
            uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
            uri.IsLoopback)
        {
            return true;
        }

        if (!uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var host = uri.Host.ToLowerInvariant();
        if (host == "github.com")
        {
            var expectedPrefix = $"/{expectedOwner.Trim()}/{expectedRepo.Trim()}/releases/download/";
            return uri.AbsolutePath.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase);
        }

        if (host == "raw.githubusercontent.com")
        {
            var expectedPrefix = $"/{expectedOwner.Trim()}/{expectedRepo.Trim()}/";
            return uri.AbsolutePath.StartsWith(expectedPrefix, StringComparison.OrdinalIgnoreCase);
        }

        return host is "objects.githubusercontent.com" or "release-assets.githubusercontent.com";
    }

    /// <summary>
    /// Builds the exact canonical UTF-8 payload signed by CI (scripts/build-launcher-release-metadata.py)
    /// and verified by the launcher before staging or installing any release.
    /// </summary>
    public static byte[] BuildCanonicalSigningPayload(LauncherReleaseMetadata metadata)
    {
        ArgumentNullException.ThrowIfNull(metadata);

        var canonical = string.Join(
            "\n",
            $"schemaVersion={metadata.SchemaVersion}",
            $"channel={NormalizeField(metadata.Channel).ToLowerInvariant()}",
            $"version={NormalizeField(metadata.Version)}",
            $"tag={NormalizeField(metadata.Tag)}",
            $"packageType={NormalizeField(metadata.PackageType).ToLowerInvariant()}",
            $"assetName={NormalizeField(metadata.AssetName)}",
            $"downloadUrl={NormalizeField(metadata.DownloadUrl)}",
            $"sha256={NormalizeField(metadata.Sha256).ToLowerInvariant()}",
            $"size={metadata.Size}",
            $"executableName={NormalizeField(metadata.ExecutableName)}",
            $"executableSha256={NormalizeField(metadata.ExecutableSha256).ToLowerInvariant()}",
            $"updaterName={NormalizeField(metadata.UpdaterName)}",
            $"updaterSha256={NormalizeField(metadata.UpdaterSha256).ToLowerInvariant()}",
            $"minUpgradeFromVersion={NormalizeField(metadata.MinUpgradeFromVersion)}");

        return Encoding.UTF8.GetBytes(canonical);
    }

    public static bool VerifySignature(
        LauncherReleaseMetadata metadata,
        string? trustedPublicKeyPem,
        bool requireSignature,
        out string reason)
    {
        ArgumentNullException.ThrowIfNull(metadata);

        var hasSignature = !string.IsNullOrWhiteSpace(metadata.SignatureBase64);
        if (!hasSignature)
        {
            if (requireSignature)
            {
                reason = "Release metadata is missing a required cryptographic signature.";
                return false;
            }

            reason = string.Empty;
            return true;
        }

        if (!string.IsNullOrWhiteSpace(metadata.SignatureAlgorithm) &&
            !string.Equals(metadata.SignatureAlgorithm.Trim(), SupportedSignatureAlgorithm, StringComparison.OrdinalIgnoreCase))
        {
            reason = $"Unsupported release signature algorithm: {metadata.SignatureAlgorithm}.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(trustedPublicKeyPem))
        {
            reason = "Release metadata includes a cryptographic signature, but no trusted public key is configured to verify it.";
            return false;
        }

        byte[] signatureBytes;
        try
        {
            signatureBytes = Convert.FromBase64String(metadata.SignatureBase64!.Trim());
        }
        catch (FormatException)
        {
            reason = "Release metadata signature is not valid Base64.";
            return false;
        }

        try
        {
            using var ecdsa = ECDsa.Create();
            ecdsa.ImportFromPem(trustedPublicKeyPem);
            var payload = BuildCanonicalSigningPayload(metadata);

            var valid = ecdsa.VerifyData(
                payload,
                signatureBytes,
                HashAlgorithmName.SHA256,
                DSASignatureFormat.Rfc3279DerSequence);
            if (!valid)
            {
                reason = "Cryptographic signature verification failed: release metadata may be corrupted or tampered.";
                return false;
            }

            reason = string.Empty;
            return true;
        }
        catch (Exception ex)
        {
            reason = $"Cryptographic signature verification error: {ex.Message}";
            return false;
        }
    }

    public static PackageVerificationResult VerifyFileIntegrity(
        string filePath,
        string? expectedSha256,
        long expectedSize,
        long minimumSizeBytes = DefaultMinimumValidExeBytes,
        bool requirePeHeader = false)
    {
        if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath))
        {
            return PackageVerificationResult.Fail("Staged update file does not exist.");
        }

        var info = new FileInfo(filePath);
        if (info.Length < minimumSizeBytes)
        {
            return PackageVerificationResult.Fail(
                $"Staged update file is smaller than minimum valid size ({info.Length} < {minimumSizeBytes} bytes).",
                sizeBytes: info.Length);
        }

        if (expectedSize > 0 && info.Length != expectedSize)
        {
            return PackageVerificationResult.Fail(
                $"Staged update file size ({info.Length} bytes) did not match expected size ({expectedSize} bytes).",
                sizeBytes: info.Length);
        }

        if (requirePeHeader && !HasPeHeader(filePath))
        {
            return PackageVerificationResult.Fail(
                "Staged executable failed Windows PE header validation (missing MZ magic).",
                sizeBytes: info.Length);
        }

        var actualSha256 = ComputeSha256Hex(filePath);
        if (!string.IsNullOrWhiteSpace(expectedSha256))
        {
            if (!IsValidSha256Hex(expectedSha256))
            {
                return PackageVerificationResult.Fail(
                    "Release metadata contains an invalid SHA-256 digest.",
                    actualSha256,
                    info.Length);
            }

            if (!string.Equals(actualSha256, expectedSha256.Trim(), StringComparison.OrdinalIgnoreCase))
            {
                return PackageVerificationResult.Fail(
                    $"SHA-256 mismatch: expected {expectedSha256.Trim().ToLowerInvariant()}, got {actualSha256}.",
                    actualSha256,
                    info.Length);
            }
        }

        return PackageVerificationResult.Ok(actualSha256, info.Length);
    }

    public static ExtractedUpdatePackage VerifyAndExtractZipPackage(
        string zipPath,
        LauncherReleaseMetadata metadata,
        string extractDir,
        long minimumExeBytes = DefaultMinimumValidExeBytes,
        bool requirePeHeader = true)
    {
        ArgumentNullException.ThrowIfNull(metadata);

        var zipCheck = VerifyFileIntegrity(
            zipPath,
            metadata.Sha256,
            metadata.Size,
            minimumSizeBytes: 128,
            requirePeHeader: false);
        if (!zipCheck.IsValid)
        {
            return new ExtractedUpdatePackage(false, string.Empty, string.Empty, null, null, zipCheck.ErrorMessage);
        }

        var expectedExeName = string.IsNullOrWhiteSpace(metadata.ExecutableName)
            ? LauncherSelfUpdateService.CanonicalLauncherExeName
            : Path.GetFileName(metadata.ExecutableName.Trim());
        var expectedUpdaterName = string.IsNullOrWhiteSpace(metadata.UpdaterName)
            ? null
            : Path.GetFileName(metadata.UpdaterName.Trim());

        if (Directory.Exists(extractDir))
        {
            Directory.Delete(extractDir, recursive: true);
        }
        Directory.CreateDirectory(extractDir);

        string? extractedExePath = null;
        string? extractedUpdaterPath = null;

        try
        {
            var fullExtractRoot = Path.GetFullPath(extractDir)
                .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;

            using var archive = ZipFile.OpenRead(zipPath);
            foreach (var entry in archive.Entries)
            {
                if (string.IsNullOrEmpty(entry.Name))
                {
                    continue;
                }

                // Reject legacy OverlordsLauncher.exe or path traversal entries
                var normalizedName = entry.FullName.Replace('\\', '/');
                if (normalizedName.Contains("..", StringComparison.Ordinal) ||
                    Path.IsPathRooted(normalizedName))
                {
                    throw new InvalidDataException($"Archive contains unsafe entry path: {entry.FullName}");
                }

                if (string.Equals(entry.Name, LauncherSelfUpdateService.LegacyLauncherExeName, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Archive contains forbidden legacy OverlordsLauncher.exe.");
                }

                var isLauncherExe = string.Equals(entry.Name, expectedExeName, StringComparison.OrdinalIgnoreCase);
                var isUpdaterExe = expectedUpdaterName is not null &&
                    string.Equals(entry.Name, expectedUpdaterName, StringComparison.OrdinalIgnoreCase);

                if (!isLauncherExe && !isUpdaterExe)
                {
                    continue;
                }

                var destPath = Path.GetFullPath(Path.Combine(extractDir, entry.Name));
                if (!destPath.StartsWith(fullExtractRoot, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException($"Archive entry escapes extraction directory: {entry.FullName}");
                }

                entry.ExtractToFile(destPath, overwrite: true);
                if (isLauncherExe)
                {
                    extractedExePath = destPath;
                }
                else if (isUpdaterExe)
                {
                    extractedUpdaterPath = destPath;
                }
            }

            if (string.IsNullOrWhiteSpace(extractedExePath) || !File.Exists(extractedExePath))
            {
                throw new InvalidDataException($"Release archive did not contain {expectedExeName}.");
            }

            var exeCheck = VerifyFileIntegrity(
                extractedExePath,
                metadata.ExecutableSha256,
                expectedSize: 0,
                minimumSizeBytes: minimumExeBytes,
                requirePeHeader: requirePeHeader);
            if (!exeCheck.IsValid)
            {
                throw new InvalidDataException($"Extracted {expectedExeName} failed verification: {exeCheck.ErrorMessage}");
            }

            string? verifiedUpdaterSha = null;
            if (!string.IsNullOrWhiteSpace(metadata.UpdaterSha256))
            {
                if (string.IsNullOrWhiteSpace(extractedUpdaterPath) || !File.Exists(extractedUpdaterPath))
                {
                    throw new InvalidDataException($"Release metadata specified {expectedUpdaterName} SHA-256, but the file was missing from the archive.");
                }

                var updaterCheck = VerifyFileIntegrity(
                    extractedUpdaterPath,
                    metadata.UpdaterSha256,
                    expectedSize: 0,
                    minimumSizeBytes: 64,
                    requirePeHeader: requirePeHeader);
                if (!updaterCheck.IsValid)
                {
                    throw new InvalidDataException($"Extracted {expectedUpdaterName} failed verification: {updaterCheck.ErrorMessage}");
                }

                verifiedUpdaterSha = updaterCheck.ComputedSha256;
            }
            else if (!string.IsNullOrWhiteSpace(extractedUpdaterPath) && File.Exists(extractedUpdaterPath))
            {
                verifiedUpdaterSha = ComputeSha256Hex(extractedUpdaterPath);
            }

            return new ExtractedUpdatePackage(
                true,
                extractedExePath,
                exeCheck.ComputedSha256,
                extractedUpdaterPath,
                verifiedUpdaterSha,
                string.Empty);
        }
        catch (Exception ex)
        {
            try
            {
                if (Directory.Exists(extractDir))
                {
                    Directory.Delete(extractDir, recursive: true);
                }
            }
            catch
            {
                // Best-effort cleanup of rejected package extraction.
            }

            return new ExtractedUpdatePackage(false, string.Empty, string.Empty, null, null, ex.Message);
        }
    }

    private static bool HasPeHeader(string filePath)
    {
        Span<byte> header = stackalloc byte[2];
        using var stream = File.OpenRead(filePath);
        return stream.Read(header) == 2 && header[0] == (byte)'M' && header[1] == (byte)'Z';
    }

    private static string NormalizeField(string? value) => (value ?? string.Empty).Trim();
}
