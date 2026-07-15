# CICD项目-阿里云部署-GitLab+Jenkins+Nginx

部署服务器要求4核8G

nginx服务器设置略

## 一、服务器部署安装

### 1）Jenkins

#### 1、安装 Jenkins 环境 - fontconfig & git

```shell
yum install -y fontconfig git
```

#### 2、安装 Jenkins 环境 - Java

```shell
wget https://cdn.azul.com/zulu/bin/zulu21.32.17-ca-jdk21.0.2-linux.x86_64.rpm
yum localinstall -y zulu21.32.17-ca-jdk21.0.2-linux.x86_64.rpm
```

#### 3、下载 Jenkins rpm 包 - 地址`https://get.jenkins.io/rpm-stable`

```shell
wget https://get.jenkins.io/rpm-stable/jenkins-2.555.1-1.noarch.rpm
```

#### 4、安装 Jenkins

```shell
yum loaclinstall -y jenkins-2.555.1-1.noarch.rpm
```

#### 5、启动 Jenkins

```shell
systemctl start jenkins
systemctl enable jenkins
```

#### 6、复制 Jenkins 密码

```shell
cat /var/lib/jenkins/secrets/initialAdminPassword
```

#### 7、通过服务器地址打开Jenkins

- 注意：ECS安全组要放通8080端口

#### 9、安装非默认插件

- `Publish over SSH`
- `Gitlab Plugin`
- `Git Plugin`

#### 10、设置凭证 - SSH Username with private key

1. 生成ssh密钥

```shell
ssh-keygen
```

2. 复制私钥

```shell
cat .ssh/id_rsa
```

3. 添加私钥到凭证
   
   ![2026-05-14-20-52-24-1f5a56d2-bed3-4704-b8f5-b93bf0300313.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-20-52-24-1f5a56d2-bed3-4704-b8f5-b93bf0300313.png)

![2026-05-14-20-57-59-c0ba1475-bde6-43f4-87b1-f0231aaac0a7.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-20-57-59-c0ba1475-bde6-43f4-87b1-f0231aaac0a7.png)

#### 11、全局安全配置

![2026-05-14-21-00-05-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-00-05-image.png)

### 2）GitLab

#### 1、下载 GitLab

```shell
wget https://packages.gitlab.cn/repository/el/7/gitlab-jh-17.7.7-jh.0.el7.x86_64.rpm
```

#### 2、gitlab安装

```shell
yum localinstall -y gitlab-ce-17.1.1-ce.0.el7.x86_64.rpm
```

#### 2、修改url

```shell
vim /etc/gitlab/gitlab.rb
```

```vim
 32 external_url 'http://192.168.103.103'
```

#### 4、初始化

```shell
gitlab-ctl reconfigure
```

#### 5、查看密码

```shell
cat /etc/gitlab/initial_root_password
```

#### 6、打开 GitLab 网站并登录

#### 7、设置出站规则

![2026-05-14-21-06-50-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-06-50-image.png)

#### 8、新建项目

## 二、CI/CD搭建

### 1）Jenkins

#### 1、新建Jenkins密钥，发送公钥到Nginx服务器

```shell
usermod -s /bin/bash jenkins
su - jenkins
ssh-keygen
ssh-copy-id root@<Nginx服务器地址>
```

#### 2、新建任务

![2026-05-14-21-09-33-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-09-33-image.png)

#### 3、设置源码管理

![2026-05-14-21-13-56-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-13-56-image.png)

- 新版GitLab分支为mian

- 如果添加url错误可添加GitLab服务为信任

```shell
ssh-keyscan <GitLab服务器地址> >> /var/lib/jenkins/.ssh/known_hosts
chown -R jenkins:jenkins /var/lib/jenkins/.ssh
chmod 700 /var/lib/jenkins/.ssh
chmod 600 /var/lib/jenkins/.ssh/known_hosts
```

#### 4、Triggers

![2026-05-14-21-24-46-2b702763-bfce-4a3a-95fc-cf075414b7bf.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-24-46-2b702763-bfce-4a3a-95fc-cf075414b7bf.png)

#### 5、Build Steps

![2026-05-14-21-31-04-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-31-04-image.png)

```vimag-0-1johvnm5kag-1-1johvnm5kag-0-1johvnm5kag-1-1johvnm5k
#!/bin/bash
#源目录为 jenkins 存放任务文件的目录
SOURCE_DIR=/var/lib/jenkins/workspace/$JOB_NAME/
#目标目录为nginx服务器的家目录
DEST_DIR=/usr/share/nginx/html 
#使用rsync同步源到nginx服务器家目录(需要免密登录),IP为nginx服务器IP
rsync -av --delete $SOURCE_DIR root@192.168.103.103:$DEST_DIR
```

#### 6、点击save保存

### 1）GitLab

#### 1、添加Nginx服务器公钥

![2026-05-14-21-44-20-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-44-20-image.png)

#### 2、添加Jenkins服务器公钥

![2026-05-14-21-48-32-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-48-32-image.png)



#### 3、设置webhook

![2026-05-14-21-38-04-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-38-04-image.png)

![2026-05-14-21-42-36-image.png](D:\user\zm\AI学习资料\CICD项目-阿里云部署-GitLab+Jenkins+Nginx\2026-05-14-21-42-36-image.png)
