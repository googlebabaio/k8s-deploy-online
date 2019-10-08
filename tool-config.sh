#!/bin/bash

configKubectlAutoSpell(){
  yum install -y bash-completion
  source /usr/share/bash-completion/bash_completion
  source <(kubectl completion bash)
}

configNStool(){
  git clone https://github.com/ahmetb/kubectx /opt/kubectx
  ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
  ln -s /opt/kubectx/kubens /usr/local/bin/ns
}
