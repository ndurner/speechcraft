# Changelog

All notable changes to this project will be documented in this file.

 ## [Unreleased]
 ### Added
 - Preferences to disable screenshot attachments in all AI requests (`EnableScreenshots`).
 - Toggle to enable/disable GPT-4o proofreading of transcripts (`EnableProofreading`).
 - Option to select GPT-4o or GPT-4o-mini as the proofreading model (`ProofreadingModel`).
 - Updated transcription flow to conditionally run proofreading or insert raw transcript based on preferences.
 - Updated screenshot capture logic to honor user preference.
 - Added new setting entries in Preferences UI under Transcription settings.

 ### Changed
 - README updated with documentation for new screenshot and proofreading settings.