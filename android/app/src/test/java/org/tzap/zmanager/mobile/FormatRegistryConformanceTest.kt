package org.tzap.zmanager.mobile

import java.io.InputStream
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Pins the app's static format knowledge to the zmanager format contract
 * snapshot (android/app/src/test/resources/format-capabilities.json), which is
 * regenerated from `zm formats --contract` by scripts/refresh-format-snapshot.sh.
 *
 * The snapshot deliberately carries kind/label/extensions only — never
 * platform-dependent status or capability flags — so it is byte-identical on
 * every build target.
 */
@RunWith(RobolectricTestRunner::class)
class FormatRegistryConformanceTest {
    private fun snapshot(): JSONObject {
        val input: InputStream = requireNotNull(javaClass.classLoader?.getResourceAsStream("format-capabilities.json")) {
            "format-capabilities.json snapshot is missing; run scripts/refresh-format-snapshot.sh"
        }
        return input.use { JSONObject(it.readBytes().decodeToString()) }
    }

    private fun rows() = snapshot().getJSONArray("formats")

    private fun registryExtensions(): Set<String> {
        val extensions = mutableSetOf<String>()
        for (index in 0 until rows().length()) {
            val rowExtensions = rows().getJSONObject(index).getJSONArray("extensions")
            for (extensionIndex in 0 until rowExtensions.length()) {
                extensions.add(rowExtensions.getString(extensionIndex).lowercase())
            }
        }
        return extensions
    }

    @Test
    fun snapshotCoversExpectedCoreKinds() {
        val kinds = (0 until rows().length()).map { rows().getJSONObject(it).getString("kind") }.toSet()
        for (expected in listOf(
            "Zip", "SevenZ", "Rar", "TarZst", "TarGz", "Tar", "TarBz2", "TarXz",
            "Tzap", "AppleArchive", "Deb", "RawStream", "SplitZip", "Iso", "Cab", "Cpio",
            "Rpm", "Xar", "Pkg", "Dmg", "Lha", "Ar", "Warc", "Mtree", "Msi", "Vhd", "Vmdk", "Udf"
        )) {
            assertTrue("snapshot is missing kind $expected", expected in kinds)
        }
    }

    @Test
    fun nestedArchiveExtensionsAreRegistrySubset() {
        // Every extension the app treats as nested-browsable exists in the
        // registry. `.tzap` is predicate-detected in core (empty extension
        // row) and is therefore allowed outside the registry's lists.
        val registry = registryExtensions()
        for (extension in NestedArchiveSupport.archiveExtensions) {
            if (extension == "tzap") continue
            assertTrue("$extension is nested-browsable but missing from the format registry", ".$extension" in registry)
        }
    }
}
