#!/bin/bash

#chmod -R +x scripts

KUBEDEPLOY_INI_FULLPATH=$(pwd)/kubedeploy.ini

echo "------------------------------------Kubernetes Install Menu----------------------------------------"
echo "| Choose your option                                                                              |"
echo "|                                                                                                 |"
echo "|                        1.Install K8s On Master (Docker)                                          |"
echo "|                        2.Install K8s On Master (containerd) - 推荐                              |"
echo "|                        3.Configure Node Environment (containerd) - 推荐                         |"
echo "|                        4.Init Env For All (OS/docker/kubelet)                                   |"
echo "|                        5.Init Env (OS/kubelet)                                                  |"
echo "|                        6.Install Docker Only                                                    |"
echo "|                        7.Uninstall K8s Config                                                   |"
echo "|                        8.Uninstall AlL Config                                                   |"
echo "|                        9.Exit                                                                   |"
echo "|                                                                                                 |"
echo "---------------------------------------------------------------------------------------------------"
echo "Choose your option (1-9):"
read answer
case $answer in
1)
	echo "使用Docker作为容器运行时..."
	sh scripts/config-master.sh ${KUBEDEPLOY_INI_FULLPATH}
	;;
2)
	echo "使用containerd作为容器运行时（推荐）..."
	sh scripts/config-master-containerd.sh ${KUBEDEPLOY_INI_FULLPATH}
	;;
3)
	echo "配置Node节点环境（containerd）..."
	sh scripts/config-node-containerd.sh ${KUBEDEPLOY_INI_FULLPATH}
	;;
4)
	sh scripts/config-initos.sh 2 ${KUBEDEPLOY_INI_FULLPATH}
	;;
5)
	sh scripts/config-initos.sh 3 ${KUBEDEPLOY_INI_FULLPATH}
	;;
6)
	sh scripts/config-initos.sh 4 ${KUBEDEPLOY_INI_FULLPATH}
	;;
7)
	sh scripts/cleank8s.sh
	;;
8)
	sh scripts/cleanall.sh
	;;
9)
	echo "byebye"
	exit 1
	;;
*)
	echo "Error! The number you input isn't 1 to 9"
	exit 1
	;;
esac
