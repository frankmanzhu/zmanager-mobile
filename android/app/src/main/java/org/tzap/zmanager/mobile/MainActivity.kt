package org.tzap.zmanager.mobile

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val incomingIntentState = mutableStateOf<Intent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incomingIntentState.value = intent
        setContent {
            ZManagerApp(
                incomingIntent = incomingIntentState.value,
                onIncomingIntentHandled = { handledIntent ->
                    if (incomingIntentState.value === handledIntent) {
                        incomingIntentState.value = null
                    }
                }
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        incomingIntentState.value = intent
    }
}

@Composable
private fun ZManagerApp(
    incomingIntent: Intent?,
    onIncomingIntentHandled: (Intent) -> Unit
) {
    val context = LocalContext.current
    val importer = remember(context) { ArchiveImporter(context) }
    val listingRepository = remember { ArchiveListingRepository() }
    val scope = rememberCoroutineScope()
    var importedArchive by remember { mutableStateOf<ImportedArchive?>(null) }
    var listingState by remember { mutableStateOf<ArchiveListingState>(ArchiveListingState.Idle) }
    var importError by remember { mutableStateOf<String?>(null) }
    var isImporting by remember { mutableStateOf(false) }
    var passwordInput by remember { mutableStateOf("") }
    var importRequestId by remember { mutableStateOf(0L) }
    var listingRequestId by remember { mutableStateOf(0L) }

    fun loadArchiveListing(archive: ImportedArchive, password: String?) {
        listingRequestId += 1
        val currentListingRequestId = listingRequestId
        listingState = ArchiveListingState.Loading
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                listingRepository.load(archive, password)
            }
            if (
                currentListingRequestId == listingRequestId &&
                importedArchive?.id == archive.id
            ) {
                listingState = result
            }
        }
    }

    fun startImport(uri: Uri) {
        importRequestId += 1
        val currentImportRequestId = importRequestId
        listingRequestId += 1
        isImporting = true
        importError = null
        importedArchive = null
        listingState = ArchiveListingState.Idle
        passwordInput = ""
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { importer.importUri(uri) }
            }
            if (currentImportRequestId != importRequestId) {
                return@launch
            }
            result
                .onSuccess { archive ->
                    importedArchive = archive
                    loadArchiveListing(archive, null)
                }
                .onFailure {
                    importError = "Unable to import that archive."
                }
            isImporting = false
        }
    }

    val documentPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri ->
        uri?.let { startImport(it) }
    }

    LaunchedEffect(incomingIntent) {
        incomingIntent?.let { intent ->
            ArchiveImportIntents.firstArchiveUri(intent)?.let { uri ->
                startImport(uri)
            }
            onIncomingIntentHandled(intent)
        }
    }

    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 24.dp, vertical = 32.dp),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Column {
                    Text(
                        text = "ZManager",
                        style = MaterialTheme.typography.headlineMedium
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Open an archive, inspect its contents, then extract safely.",
                        style = MaterialTheme.typography.bodyLarge
                    )
                    Spacer(modifier = Modifier.height(24.dp))
                    importedArchive?.let { archive ->
                        Text(
                            text = "Imported ${archive.displayName}",
                            style = MaterialTheme.typography.titleMedium
                        )
                        archive.byteSize?.let { size ->
                            Spacer(modifier = Modifier.height(4.dp))
                            Text(
                                text = "$size bytes copied into app cache",
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                    importError?.let { message ->
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.error
                        )
                    }
                    ArchiveListingPanel(
                        state = listingState,
                        passwordInput = passwordInput,
                        onPasswordInputChanged = { passwordInput = it },
                        onSubmitPassword = {
                            importedArchive?.let { archive ->
                                val password = passwordInput.takeIf { it.isNotEmpty() }
                                passwordInput = ""
                                loadArchiveListing(archive, password)
                            }
                        }
                    )
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End)
                ) {
                    Button(
                        enabled = !isImporting,
                        onClick = { documentPicker.launch(arrayOf("*/*")) }
                    ) {
                        Text(if (isImporting) "Importing" else "Open Archive")
                    }
                }
            }
        }
    }
}

@Composable
private fun ArchiveListingPanel(
    state: ArchiveListingState,
    passwordInput: String,
    onPasswordInputChanged: (String) -> Unit,
    onSubmitPassword: () -> Unit
) {
    when (state) {
        ArchiveListingState.Idle -> Unit
        ArchiveListingState.Loading -> {
            Text(
                text = "Reading archive",
                style = MaterialTheme.typography.bodyMedium
            )
        }
        is ArchiveListingState.Ready -> ArchiveListingReadyPanel(state.summary)
        is ArchiveListingState.PasswordRequired -> {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            OutlinedTextField(
                value = passwordInput,
                onValueChange = onPasswordInputChanged,
                label = { Text("Password") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                enabled = passwordInput.isNotEmpty(),
                onClick = onSubmitPassword
            ) {
                Text("Retry")
            }
        }
        is ArchiveListingState.Failed -> {
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = state.error.message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.error
            )
            state.error.recoveryHint?.let { hint ->
                Text(
                    text = hint,
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}

@Composable
private fun ArchiveListingReadyPanel(summary: ArchiveListingSummary) {
    Spacer(modifier = Modifier.height(8.dp))
    Text(
        text = "${summary.formatLabel} - ${summary.entryCount} entries",
        style = MaterialTheme.typography.titleMedium
    )
    summary.totalSize?.let { totalSize ->
        Text(
            text = "$totalSize bytes total",
            style = MaterialTheme.typography.bodyMedium
        )
    }
    summary.warnings.forEach { warning ->
        Text(
            text = warning,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error
        )
    }
    LazyColumn(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 240.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    ) {
        items(summary.entries) { entry ->
            Column {
                Text(
                    text = entry.path,
                    style = MaterialTheme.typography.bodyMedium
                )
                Text(
                    text = listOfNotNull(
                        entry.kind.name.lowercase().replace('_', ' '),
                        entry.size?.let { "$it bytes" }
                    ).joinToString(" - "),
                    style = MaterialTheme.typography.bodySmall
                )
            }
        }
    }
}
