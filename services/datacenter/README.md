# Datacenter

This folder is reserved for the future datacenter-side implementation of
Aileen 4 Disaster Relief.

The current browser-accessible trusted-recipient prototype lives in
`services/relay-desk/`. That Gradio app opens a field package, runs Gemma 4 E4B
on Hugging Face ZeroGPU, renders the labeled story visual with Python image
tooling, and exports recipient artifacts for the Desk Mode workflow.

Expected future responsibilities:

- server-side media-rendering workers if product needs outgrow the Apple client
- higher-throughput model serving
- orchestration APIs for Apple clients
- shared asset and campaign state

It is intentionally a placeholder for now so the repository structure accounts
for the second product component from the start.
