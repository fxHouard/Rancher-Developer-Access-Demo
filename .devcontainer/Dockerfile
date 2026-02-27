FROM dp.apps.rancher.io/containers/nodejs:24-dev

# System tools (available in the SLE_BCI repo)
# gawk: required by VS Code Server (check-requirements.sh)
RUN zypper --non-interactive install -y git openssh make gawk \
    && zypper clean -a
