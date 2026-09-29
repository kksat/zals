package com.kksat.zals

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.ProjectWideLspServerDescriptor
import com.kksat.zals.settings.ZalsSettings

class ZalsLspServerDescriptor(project: Project) : ProjectWideLspServerDescriptor(project, "zals") {

    override fun isSupportedFile(file: VirtualFile): Boolean {
        val name = file.name
        val ext = file.extension?.lowercase()
        if (ext != "yml" && ext != "yaml") {
            return false
        }

        // Direct filename matches
        if (name == "playbook.yml" || name == "playbook.yaml" ||
            name == "site.yml" || name == "site.yaml" ||
            name == "requirements.yml" || name == "galaxy.yml" ||
            name == "execution-environment.yml" ||
            name.endsWith(".ansible.yml") || name.endsWith(".ansible.yaml")
        ) {
            return true
        }

        // Structural directory matches in Ansible projects
        val path = file.path
        return path.contains("/playbooks/") ||
                path.contains("/roles/") ||
                path.contains("/tasks/") ||
                path.contains("/handlers/") ||
                path.contains("/defaults/") ||
                path.contains("/vars/") ||
                path.contains("/meta/") ||
                path.contains("/host_vars/") ||
                path.contains("/group_vars/") ||
                path.contains("/molecule/")
    }

    override fun createCommandLine(): GeneralCommandLine {
        val settings = ZalsSettings.instance
        val command = if (settings.executablePath.isNotBlank()) {
            settings.executablePath
        } else {
            "zals"
        }

        return GeneralCommandLine().apply {
            withExePath(command)
            addParameter("--stdio")
            withWorkDirectory(project.basePath)
        }
    }

    override fun createInitializationOptions(): Any {
        val settings = ZalsSettings.instance
        return mapOf(
            "ansible" to mapOf(
                "validation" to mapOf(
                    "enabled" to settings.validationEnabled,
                    "lint" to mapOf(
                        "enabled" to settings.lintEnabled,
                        "path" to settings.lintPath
                    )
                ),
                "ansible" to mapOf(
                    "path" to "ansible",
                    "useFullyQualifiedCollectionNames" to true
                ),
                "completion" to mapOf(
                    "provideRedirectModules" to true,
                    "provideDisabledModules" to true
                )
            )
        )
    }

    override fun findRootForFile(file: VirtualFile): VirtualFile? {
        var current: VirtualFile? = file.parent
        while (current != null) {
            if (current.findChild("ansible.cfg") != null ||
                current.findChild(".git") != null ||
                current.findChild("requirements.yml") != null ||
                current.findChild("galaxy.yml") != null
            ) {
                return current
            }
            current = current.parent
        }
        return project.baseDir
    }
}
