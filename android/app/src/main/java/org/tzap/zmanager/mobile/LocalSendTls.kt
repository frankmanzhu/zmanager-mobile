package org.tzap.zmanager.mobile

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** TLS helpers for LocalSend's self-signed, certificate-fingerprint protocol. */
object LocalSendTls {
    private val permissiveHostnameVerifier = HostnameVerifier { _, _ -> true }

    fun normalizeFingerprint(value: String): String =
        value.filter(Char::isLetterOrDigit).uppercase()

    fun configure(connection: HttpsURLConnection, fingerprint: String?, allowUntrusted: Boolean) {
        connection.hostnameVerifier = permissiveHostnameVerifier
        connection.sslSocketFactory = if (allowUntrusted) {
            trustAllSocketFactory()
        } else {
            pinnedSocketFactory(fingerprint)
        }
    }

    fun certificateFingerprint(connection: HttpsURLConnection): String? {
        val certificate = connection.serverCertificates.firstOrNull() as? X509Certificate
            ?: return null
        return certificateFingerprint(certificate)
    }

    private fun certificateFingerprint(certificate: X509Certificate): String =
        MessageDigest.getInstance("SHA-256")
            .digest(certificate.encoded)
            .joinToString("") { "%02X".format(it) }

    private fun pinnedSocketFactory(fingerprint: String?): SSLSocketFactory {
        val expected = fingerprint?.let(::normalizeFingerprint)
            ?.takeIf { it.length == 64 }
            ?: throw IllegalArgumentException("HTTPS LocalSend peers must provide a certificate fingerprint.")
        val trustManager = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit

            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val leaf = chain.firstOrNull()
                    ?: throw CertificateException("LocalSend peer returned no certificate.")
                if (certificateFingerprint(leaf) != expected) {
                    throw CertificateException("LocalSend certificate fingerprint did not match the selected device.")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        return socketFactory(trustManager)
    }

    private fun trustAllSocketFactory(): SSLSocketFactory = socketFactory(object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    })

    private fun socketFactory(trustManager: X509TrustManager): SSLSocketFactory {
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(trustManager), null)
        return context.socketFactory
    }
}
