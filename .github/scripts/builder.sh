curl -qfsSL "https://raw.githubusercontent.com/ivan-hc/AM/main/AM-INSTALLER" | bash -s 


wget -q https://raw.githubusercontent.com/ivan-hc/AM/main/AM-INSTALLER && chmod a+x ./AM-INSTALLER && ./AM-INSTALLER



sudo apt-get -y update 2> /dev/null || apt-get -y update
sudo apt-get -y install wget curl torsocks zsync 2> /dev/null || apt-get -y install git wget curl torsocks zsync


yes '1' | bash <(curl -qfsSL "https://raw.githubusercontent.com/ivan-hc/AM/main/AM-INSTALLER")

if ! command -v am &>/dev/null; then
  echo -e "[-] Failed to find am\n"
 exit 1
else
  am -l --appimages
fi