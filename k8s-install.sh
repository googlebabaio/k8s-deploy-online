#!/bin/bash

#chmod -R +x scripts

KUBEDEPLOY_INI_FULLPATH=$(pwd)/kubedeploy.ini

echo "------------------------------------Kubernetes Install Menu----------------------------------------"
echo "| Choose your option                                                                              |"
echo "|                                                                                                 |"
echo "|                        1.Install K8s On Master                                                  |"
echo "|                        2.Init Env For All (OS/docker/kubelet)                                   |"
echo "|                        3.Init Env (OS/kubelet)                                                  |"
echo "|                        4.Install Docker Only                                                    |"
echo "|                        5.Uninstall K8s Config                                                   |"
echo "|                        6.Uninstall AlL Config                                                   |"
echo "|                        7.Exit                                                                   |"
echo "|                                                                                                 |"
echo "---------------------------------------------------------------------------------------------------"
echo "Choose your option (1-10):"
read answer
case $answer in
1)
	sh scripts/config-master.sh ${KUBEDEPLOY_INI_FULLPATH}
	;;
2)
	sh scripts/config-initos.sh 2 ${KUBEDEPLOY_INI_FULLPATH}
	;;
3)
	sh scripts/config-initos.sh 3 ${KUBEDEPLOY_INI_FULLPATH}
	;;
4)
	sh scripts/config-initos.sh 4 ${KUBEDEPLOY_INI_FULLPATH}
	;;
5)
	sh scripts/cleank8s.sh
	;;
6)
	sh scripts/cleanall.sh
	;;
7)
	echo "byebye"
	exit 1
	;;
*)
	echo "Error! The number you input isn't 1 to 7"
	exit 1
	;;
esac
