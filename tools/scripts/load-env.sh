# Sourced from the repository root by deploy.sh and tools/scripts: picks env/<ENVIRONMENT>.mk
# (the same file the Makefile includes) and exports its variables as ENV_FILE. ENVIRONMENT must be
# dev, prod or sepolia (Sepolia twins of the prod contracts, see env/sepolia.mk), there is no default.
case "${ENVIRONMENT:-}" in
    dev|prod|sepolia) ;;
    "") echo "ENVIRONMENT is not set: ENVIRONMENT=dev|prod|sepolia" >&2; exit 1 ;;
    *) echo "Unknown ENVIRONMENT=$ENVIRONMENT, expected dev, prod or sepolia" >&2; exit 1 ;;
esac

ENV_FILE="env/$ENVIRONMENT.mk"
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE in $(pwd)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
