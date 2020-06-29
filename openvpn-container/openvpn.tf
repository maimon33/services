# Create a new instance of the latest Ubuntu 14.04 on an
# t2.micro node with an AWS Tag naming it "HelloWorld"
provider "aws" {
  region = "eu-west-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-*.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

data "http" "myip" {
  url = "http://ipv4.icanhazip.com"
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "openvpn-key" {
  key_name   = "openvpn-key"
  public_key = tls_private_key.ssh.public_key_openssh

  provisioner "local-exec" {
    command = "echo \"${tls_private_key.ssh.private_key_pem}\" > ./openvpn-key; chmod 400 ./openvpn-key"
  }

  provisioner "local-exec" {
    when = destroy
    command = "rm openvpn-key"
  }
}

resource "aws_iam_instance_profile" "openvpn_profile" {
  name = "openvpn_profile"
  role = aws_iam_role.openvpn_role.name
}

resource "aws_iam_role_policy" "openvpn_policy" {
  name = "openvpn_policy"
  role = aws_iam_role.openvpn_role.id

  policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": [
          "s3:*"
        ],
        "Effect": "Allow",
        "Resource": "*"
      }
    ]
  }
  EOF
}

resource "aws_iam_role" "openvpn_role" {
  name = "openvpn_role"

  assume_role_policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
      }
    ]
  }
  EOF
}

#resource "aws_s3_bucket" "openvpn-bucket" {
#  bucket = aws_instance.openvpn.id
#  acl    = "private"
#
#  tags = {
#    Name        = "Openvpn S3 bucket"
#    Environment = "Dev"
#  }
#}

resource "aws_eip" "openvpn_eip" {
  instance = aws_instance.openvpn.id
  vpc      = true
}

resource "aws_security_group" "allow_openvpn" {
  name        = "allow_openvpn"
  description = "Allow Openvpn inbound traffic"

  ingress {
    description = "Openvpn from VPC"
    from_port   = 1194
    to_port     = 1194
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH from users IP"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${chomp(data.http.myip.body)}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Openvpn"
  }
}

#resource "aws_key_pair" "openvpn" {
#  key_name   = "openvpn-key"
#  public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAABJQAAAQEAsV4UsJCsDuHkCF1QGyNWKKaNeygHutHpRqTlPwiM2XbHX0w56P1TbMhn8Pt21PgoX98f8YFbCZhxMH2uqGNz/Km5re6wM7WjMX9G4UmHaX2Llt//5l3wyZn7KWzK9HKqC8MsV3VZrVIskeVq/A4u9kyY0FCia1th7CceGQCwJA62+vDr3WEkaHkCEU+B1pXLnAHOqkk0CBDqO9K36vf1EVFAqfupYfFzxTCMj2jwkXN1F5A8ca7FU08m+bRv9Fcgcwe110RKhSMgTD05V+dmsaN6xShp+3OO44zDQgQ+pMjioRWrrqOnhWreXKjxBRhMaXgCRhON8yY8fqbJRpSfuQ== rsa-key-20200620"
#}

resource "aws_instance" "openvpn" {
  ami                     = data.aws_ami.ubuntu.id
  key_name                = "openvpn-key"
  instance_type           = "t2.micro"
  vpc_security_group_ids  = [ aws_security_group.allow_openvpn.id ]
  iam_instance_profile    = aws_iam_instance_profile.openvpn_profile.name

  provisioner "file" {
    source      = "source"
    destination = "/home/ubuntu/openvpn"
  }

  provisioner "remote-exec" {
    inline = [
      "cd /home/ubuntu/openvpn && chmod +x *.sh && ./install-docker.sh",
      "sudo usermod -aG docker ubuntu",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      "cd /home/ubuntu/openvpn && docker build . -t openvpn-container",
      "set -x && metadata='http://169.254.169.254/latest/meta-data'",
      "mac=$(curl -s $metadata/network/interfaces/macs/ | head -n1 | tr -d '/')",
      "cidr=$(curl -s $metadata/network/interfaces/macs/$mac/vpc-ipv4-cidr-block/)",
      "docker run -d -v /home/ubuntu/openvpn:/etc/openvpn -e NETWORK=\"$cidr\" -p 1194:1194/udp --privileged --restart on-failure openvpn-container:latest",
    ]
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    password    = ""
    // private_key = file("./openvpn-key")
    #("openvpn-key")
    host        = self.public_ip
  }
  
  tags = {
    Name = "Openvpn"
  }
}