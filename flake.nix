{
  description = "Epitech Seminar DOP - Bernstein Project (DigitalOcean & Kubernetes)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            kubectl
            terraform
            k9s
            kubernetes-helm
            minikube
          ];

          shellHook = ''
            # Load environment variables from local .env
            if [ -f .env ]; then
              source .env
            fi

            # Clean terminal and print a professional header
            echo -e "\033[1;36m"
            cat << "EOF"
  ____  _____ ____  _   _ ____ _____ _____ ___ _   _ 
 | __ )| ____|  _ \| \ | / ___|_   _| ____|_ _| \ | |
 |  _ \|  _| | |_) |  \| \___ \ | | |  _|  | ||  \| |
 | |_) | |___|  _ <| |\  |___) || | | |___ | || |\  |
 |____/|_____|_| \_\_| \_|____/ |_| |_____|___|_| \_|
                                                     
         DigitalOcean Cloud Project Environment      
EOF
            echo -e "\033[0m"

            # Check environment status
            echo -e "\033[1;33m--- ENVIRONMENT STATUS ---\033[0m"
            
            # Helper function to check package
            check_tool() {
              if command -v $1 >/dev/null 2>&1; then
                version=""
                if [ "$1" = "kubectl" ]; then
                  version=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -n 1)
                else
                  version=$($1 --version 2>/dev/null | head -n 1 || $1 version 2>/dev/null | head -n 1)
                fi
                echo -e "  \033[0;32m✓\033[0m \033[1m$1\033[0m: $version"
              else
                echo -e "  \033[0;31m✗ $1\033[0m (not installed)"
              fi
            }

            check_tool kubectl
            check_tool minikube
            check_tool k9s
            check_tool helm
            check_tool terraform

            echo ""
            echo -e "\033[1;33m--- DIGITALOCEAN API STATUS ---\033[0m"
            if [ -n "$DIGITALOCEAN_TOKEN" ] && [ "$DIGITALOCEAN_TOKEN" != "METTRE_ICI_VOTRE_JETON_API" ]; then
              echo -e "  \033[0;32m✓\033[0m DIGITALOCEAN_TOKEN is loaded"
            else
              echo -e "  \033[0;31m✗\033[0m DIGITALOCEAN_TOKEN is NOT configured in .env"
            fi

            # Define useful Kubernetes developer aliases
            alias k="kubectl"
            alias kgp="kubectl get pods"
            alias kgs="kubectl get services"
            alias kgd="kubectl get deployments"
            alias kd="kubectl describe"
            alias kl="kubectl logs"
            alias kexec="kubectl exec -it"
            alias tf="terraform"

            echo ""
            echo -e "\033[1;33m--- HANDY ALIASES ACTIVATED ---\033[0m"
            echo -e "  \033[1mk\033[0m     -> kubectl"
            echo -e "  \033[1mtf\033[0m    -> terraform"
            echo -e "  \033[1mkgp\033[0m   -> kubectl get pods"
            echo -e "  \033[1mkgs\033[0m   -> kubectl get services"
            echo -e "  \033[1mkd\033[0m    -> kubectl describe"
            echo -e "  \033[1mkl\033[0m    -> kubectl logs"
            echo -e "  \033[1mk9s\033[0m   -> Launch Kubernetes TUI dashboard"
            
            echo ""
            echo -e "\033[1;35mQUICK START:\033[0m"
            echo -e "  1. Set your token in the .env file."
            echo -e "  2. Provision DOKS: cd terraform && tf init && tf apply"
            echo -e "  3. Deploy stack:   k apply -f <manifest>.yaml"
            echo ""
          '';
        };
      });
}
