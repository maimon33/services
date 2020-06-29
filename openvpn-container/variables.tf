variable "public_key_path" {
  description = <<DESCRIPTION
Path to the SSH public key to be used for authentication.
Ensure this keypair is added to your local SSH agent so provisioners can
connect.
Example: ~/.ssh/terraform.pub
DESCRIPTION
  default = "C:\Users\Assi\.ssh\assi-win.pem"
}

variable "key_name" {
  description = "Desired name of AWS key pair"
  default = "assi-win"
}