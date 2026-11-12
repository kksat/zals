package com.kksat.zals

import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspServerSupportProvider

class ZalsLspServerSupportProvider : LspServerSupportProvider {
    override fun fileOpened(
        project: Project,
        file: VirtualFile,
        serverStarter: LspServerSupportProvider.LspServerStarter
    ) {
        val descriptor = ZalsLspServerDescriptor(project)
        if (descriptor.isSupportedFile(file)) {
            serverStarter.ensureServerStarted(descriptor)
        }
    }
}
