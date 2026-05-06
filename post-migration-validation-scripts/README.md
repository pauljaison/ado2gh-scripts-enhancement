## This folder is for ado2gh post-migration-validation enhanced scripts

Enhancement 1:  The existing ADO2GH post-migration validation script compares all branches between Azure DevOps and GitHub repositories, including branch count, commit count and SHA values. This logic needs to be refined to validate only the main branch as part of the post-migration verification process.

Enhancement 2: Extra condition adding for post-migration-validation to compare if the branch count within 10 means it will do comparison for all 10 branches otherwise it will do for only the default branch

